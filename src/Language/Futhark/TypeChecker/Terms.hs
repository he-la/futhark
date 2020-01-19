{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances, DeriveFunctor #-}
{-# Language TupleSections #-}
-- | Facilities for type-checking Futhark terms.  Checking a term
-- requires a little more context to track uniqueness and such.
--
-- Type inference is implemented through a variation of
-- Hindley-Milner.  The main complication is supporting the rich
-- number of built-in language constructs, as well as uniqueness
-- types.  This is mostly done in an ad hoc way, and many programs
-- will require the programmer to fall back on type annotations.
module Language.Futhark.TypeChecker.Terms
  ( checkOneExp
  , checkFunDef
  )
where
import Debug.Trace
import Control.Monad.Identity
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.RWS hiding (Sum)
import Control.Monad.Writer hiding (Sum)
import qualified Control.Monad.Fail as Fail
import Data.Bifunctor
import Data.Char (isAscii)
import Data.Either
import Data.List
import qualified Data.List.NonEmpty as NE
import Data.Loc
import Data.Maybe
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Prelude hiding (mod)

import Language.Futhark
import Language.Futhark.Semantic (includeToString)
import Language.Futhark.Traversals
import Language.Futhark.TypeChecker.Monad hiding (BoundV, checkQualNameWithEnv)
import Language.Futhark.TypeChecker.Types hiding (checkTypeDecl)
import Language.Futhark.TypeChecker.Unify hiding (Usage)
import qualified Language.Futhark.TypeChecker.Types as Types
import qualified Language.Futhark.TypeChecker.Monad as TypeM
import Futhark.Util.Pretty hiding (space, bool, group)

--- Uniqueness

data Usage = Consumed SrcLoc
           | Observed SrcLoc
           deriving (Eq, Ord, Show)

type Names = S.Set VName

-- | The consumption set is a Maybe so we can distinguish whether a
-- consumption took place, but the variable went out of scope since,
-- or no consumption at all took place.
data Occurence = Occurence { observed :: Names
                           , consumed :: Maybe Names
                           , location :: SrcLoc
                           }
             deriving (Eq, Show)

instance Located Occurence where
  locOf = locOf . location

observation :: Aliasing -> SrcLoc -> Occurence
observation = flip Occurence Nothing . S.map aliasVar

consumption :: Aliasing -> SrcLoc -> Occurence
consumption = Occurence S.empty . Just . S.map aliasVar

-- | A null occurence is one that we can remove without affecting
-- anything.
nullOccurence :: Occurence -> Bool
nullOccurence occ = S.null (observed occ) && isNothing (consumed occ)

-- | A seminull occurence is one that does not contain references to
-- any variables in scope.  The big difference is that a seminull
-- occurence may denote a consumption, as long as the array that was
-- consumed is now out of scope.
seminullOccurence :: Occurence -> Bool
seminullOccurence occ = S.null (observed occ) && maybe True S.null (consumed occ)

type Occurences = [Occurence]

type UsageMap = M.Map VName [Usage]

usageMap :: Occurences -> UsageMap
usageMap = foldl comb M.empty
  where comb m (Occurence obs cons loc) =
          let m' = S.foldl' (ins $ Observed loc) m obs
          in S.foldl' (ins $ Consumed loc) m' $ fromMaybe mempty cons
        ins v m k = M.insertWith (++) k [v] m

combineOccurences :: MonadTypeChecker m => VName -> Usage -> Usage -> m Usage
combineOccurences _ (Observed loc) (Observed _) = return $ Observed loc
combineOccurences name (Consumed wloc) (Observed rloc) =
  useAfterConsume (baseName name) rloc wloc
combineOccurences name (Observed rloc) (Consumed wloc) =
  useAfterConsume (baseName name) rloc wloc
combineOccurences name (Consumed loc1) (Consumed loc2) =
  consumeAfterConsume (baseName name) (max loc1 loc2) (min loc1 loc2)

checkOccurences :: MonadTypeChecker m => Occurences -> m ()
checkOccurences = void . M.traverseWithKey comb . usageMap
  where comb _    []     = return ()
        comb name (u:us) = foldM_ (combineOccurences name) u us

allObserved :: Occurences -> Names
allObserved = S.unions . map observed

allConsumed :: Occurences -> Names
allConsumed = S.unions . map (fromMaybe mempty . consumed)

allOccuring :: Occurences -> Names
allOccuring occs = allConsumed occs <> allObserved occs

anyConsumption :: Occurences -> Maybe Occurence
anyConsumption = find (isJust . consumed)

seqOccurences :: Occurences -> Occurences -> Occurences
seqOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt occurs1 ++ occurs2
  where filt occ =
          occ { observed = observed occ `S.difference` postcons }
        postcons = allConsumed occurs2

altOccurences :: Occurences -> Occurences -> Occurences
altOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt1 occurs1 ++ map filt2 occurs2
  where filt1 occ =
          occ { consumed = S.difference <$> consumed occ <*> pure cons2
              , observed = observed occ `S.difference` cons2 }
        filt2 occ =
          occ { consumed = consumed occ
              , observed = observed occ `S.difference` cons1 }
        cons1 = allConsumed occurs1
        cons2 = allConsumed occurs2

--- Scope management

-- | Whether something is a global or a local variable.
data Locality = Local | Global
              deriving (Show)

data ValBinding = BoundV Locality [TypeParam] PatternType
                -- ^ Aliases in parameters indicate the lexical
                -- closure.
                | OverloadedF [PrimType] [Maybe PrimType] (Maybe PrimType)
                | EqualityF
                | WasConsumed SrcLoc
                deriving (Show)

-- | Type checking happens with access to this environment.  The
-- 'TermScope' will be extended during type-checking as bindings come into
-- scope.
data TermEnv = TermEnv { termScope :: TermScope
                       , termBreadCrumbs :: [BreadCrumb]
                         -- ^ Most recent first.
                       , termLevel :: Level
                       }

data TermScope = TermScope { scopeVtable  :: M.Map VName ValBinding
                           , scopeTypeTable :: M.Map VName TypeBinding
                           , scopeModTable :: M.Map VName Mod
                           , scopeNameMap :: NameMap
                           } deriving (Show)

instance Semigroup TermScope where
  TermScope vt1 tt1 mt1 nt1 <> TermScope vt2 tt2 mt2 nt2 =
    TermScope (vt2 `M.union` vt1) (tt2 `M.union` tt1) (mt1 `M.union` mt2) (nt2 `M.union` nt1)

envToTermScope :: Env -> TermScope
envToTermScope env = TermScope { scopeVtable = vtable
                               , scopeTypeTable = envTypeTable env
                               , scopeNameMap = envNameMap env
                               , scopeModTable = envModTable env
                               }
  where vtable = M.mapWithKey valBinding $ envVtable env
        valBinding k (TypeM.BoundV tps v) =
          BoundV Global tps $ v `setAliases`
          (if arrayRank v > 0 then S.singleton (AliasBound k) else mempty)

withEnv :: TermEnv -> Env -> TermEnv
withEnv tenv env = tenv { termScope = termScope tenv <> envToTermScope env }

overloadedTypeVars :: Constraints -> Names
overloadedTypeVars = mconcat . map f . M.elems
  where f (_, HasFields fs _) = mconcat $ map typeVars $ M.elems fs
        f _ = mempty

-- | Get the type of an expression, with all type variables
-- substituted.  Never call 'typeOf' directly (except in a few
-- carefully inspected locations)!
expType :: Exp -> TermTypeM PatternType
expType = normaliseType . typeOf

-- | What was the source of some existential size?  This is used for
-- using the same existential variable if the same source is
-- encountered in multiple locations.
data SizeSource = SourceExp (ExpBase NoInfo VName)
                | SourceSlice
                  (Maybe (DimDecl VName))
                  (Maybe (ExpBase NoInfo VName))
                  (Maybe (ExpBase NoInfo VName))
                  (Maybe (ExpBase NoInfo VName))
                deriving (Eq, Ord, Show)

-- | The state is a set of constraints and a counter for generating
-- type names.  This is distinct from the usual counter we use for
-- generating unique names, as these will be user-visible.
data TermTypeState = TermTypeState
                     { stateConstraints :: Constraints
                     , stateCounter :: Int
                     , stateDimTable :: M.Map SizeSource VName
                       -- ^ Mapping function arguments encountered to
                       -- the sizes they ended up generating (when
                       -- they could not be substituted directly).
                       -- This happens for function arguments that are
                       -- not constants or names.
                     }

newtype TermTypeM a = TermTypeM (RWST
                                 TermEnv
                                 Occurences
                                 TermTypeState
                                 TypeM
                                 a)
  deriving (Monad, Functor, Applicative,
            MonadReader TermEnv,
            MonadWriter Occurences,
            MonadState TermTypeState,
            MonadError TypeError)

instance Fail.MonadFail TermTypeM where
  fail = typeError (noLoc :: SrcLoc) . ("unknown failure (likely a bug): "++)

instance MonadUnify TermTypeM where
  getConstraints = gets stateConstraints
  putConstraints x = modify $ \s -> s { stateConstraints = x }

  newTypeVar loc desc = do
    i <- incCounter
    v <- newID $ mkTypeVarName desc i
    constrain v $ NoConstraint Lifted $ mkUsage' loc
    return $ Scalar $ TypeVar mempty Nonunique (typeName v) []


  curLevel = asks termLevel

  newDimVar loc rigidity name = do
    i <- incCounter
    dim <- newID $ mkTypeVarName name i
    case rigidity of
      Rigid -> constrain dim $ UnknowableSize loc
      Nonrigid -> constrain dim $ Size Nothing $ mkUsage' loc
    return dim

instance MonadBreadCrumbs TermTypeM where
  breadCrumb bc = local $ \env ->
    env { termBreadCrumbs = bc : termBreadCrumbs env }
  getBreadCrumbs = asks termBreadCrumbs

runTermTypeM :: TermTypeM a -> TypeM (a, Occurences)
runTermTypeM (TermTypeM m) = do
  initial_scope <- (initialTermScope <>) . envToTermScope <$> askEnv
  let initial_tenv = TermEnv { termScope = initial_scope
                             , termBreadCrumbs = mempty
                             , termLevel = 0
                             }
  evalRWST m initial_tenv $ TermTypeState mempty 0 mempty

liftTypeM :: TypeM a -> TermTypeM a
liftTypeM = TermTypeM . lift

localScope :: (TermScope -> TermScope) -> TermTypeM a -> TermTypeM a
localScope f = local $ \tenv -> tenv { termScope = f $ termScope tenv }

incCounter :: TermTypeM Int
incCounter = do s <- get
                put s { stateCounter = stateCounter s + 1 }
                return $ stateCounter s

extSize :: SrcLoc -> SizeSource -> TermTypeM (DimDecl VName, Maybe VName)
extSize loc e = do
  prev <- gets $ M.lookup e . stateDimTable
  case prev of
    Nothing -> do
      d <- newDimVar loc Rigid "argdim"
      modify $ \s -> s { stateDimTable = M.insert e d $ stateDimTable s }
      return (NamedDim $ qualName d,
              Just d)
    Just d -> return (NamedDim $ qualName d, Nothing)

constrain :: VName -> Constraint -> TermTypeM ()
constrain v c = do
  lvl <- curLevel
  modifyConstraints $ M.insert v (lvl, c)

incLevel :: TermTypeM a -> TermTypeM a
incLevel = local $ \env -> env { termLevel = termLevel env + 1 }

initialTermScope :: TermScope
initialTermScope = TermScope { scopeVtable = initialVtable
                             , scopeTypeTable = mempty
                             , scopeNameMap = topLevelNameMap
                             , scopeModTable = mempty
                             }
  where initialVtable = M.fromList $ mapMaybe addIntrinsicF $ M.toList intrinsics

        prim = Scalar . Prim
        arrow x y = Scalar $ Arrow mempty Unnamed x y

        addIntrinsicF (name, IntrinsicMonoFun pts t) =
          Just (name, BoundV Global [] $ arrow pts' $ prim t)
          where pts' = case pts of [pt] -> prim pt
                                   _    -> tupleRecord $ map prim pts

        addIntrinsicF (name, IntrinsicOverloadedFun ts pts rts) =
          Just (name, OverloadedF ts pts rts)
        addIntrinsicF (name, IntrinsicPolyFun tvs pts rt) =
          Just (name, BoundV Global tvs $
                      fromStruct $ Scalar $ Arrow mempty Unnamed pts' rt)
          where pts' = case pts of [pt] -> pt
                                   _    -> tupleRecord pts
        addIntrinsicF (name, IntrinsicEquality) =
          Just (name, EqualityF)
        addIntrinsicF _ = Nothing

instance MonadTypeChecker TermTypeM where
  warn loc problem = liftTypeM $ warn loc problem
  newName = liftTypeM . newName
  newID = liftTypeM . newID

  checkQualName space name loc = snd <$> checkQualNameWithEnv space name loc

  bindNameMap m = localScope $ \scope ->
    scope { scopeNameMap = m <> scopeNameMap scope }

  bindVal v (TypeM.BoundV tps t) = localScope $ \scope ->
    scope { scopeVtable = M.insert v vb $ scopeVtable scope }
    where vb = BoundV Local tps $ fromStruct t

  lookupType loc qn = do
    outer_env <- liftTypeM askEnv
    (scope, qn'@(QualName qs name)) <- checkQualNameWithEnv Type qn loc
    case M.lookup name $ scopeTypeTable scope of
      Nothing -> undefinedType loc qn
      Just (TypeAbbr l ps def) ->
        return (qn', ps, qualifyTypeVars outer_env (map typeParamName ps) qs def, l)

  lookupMod loc qn = do
    (scope, qn'@(QualName _ name)) <- checkQualNameWithEnv Term qn loc
    case M.lookup name $ scopeModTable scope of
      Nothing -> unknownVariableError Term qn loc
      Just m  -> return (qn', m)

  lookupVar loc qn = do
    outer_env <- liftTypeM askEnv
    (scope, qn'@(QualName qs name)) <- checkQualNameWithEnv Term qn loc
    let usage = mkUsage loc $ "use of " ++ quote (pretty qn)

    t <- case M.lookup name $ scopeVtable scope of
      Nothing -> throwError $ TypeError loc $
                 "Unknown variable " ++ quote (pretty qn) ++ "."

      Just (WasConsumed wloc) -> useAfterConsume (baseName name) loc wloc

      Just (BoundV _ tparams t)
        | "_" `isPrefixOf` baseString name -> underscoreUse loc qn
        | otherwise -> do
            (tnames, t') <- instantiateTypeScheme loc tparams t
            return $ qualifyTypeVars outer_env tnames qs t'

      Just EqualityF -> do
        argtype <- newTypeVar loc "t"
        equalityType usage argtype
        return $
          Scalar $ Arrow mempty Unnamed argtype $
          Scalar $ Arrow mempty Unnamed argtype $ Scalar $ Prim Bool

      Just (OverloadedF ts pts rt) -> do
        argtype <- newTypeVar loc "t"
        mustBeOneOf ts usage argtype
        let (pts', rt') = instOverloaded argtype pts rt
            arrow xt yt = Scalar $ Arrow mempty Unnamed xt yt
        return $ fromStruct $ foldr arrow rt' pts'

    observe $ Ident name (Info t) loc
    return (qn', t)

      where instOverloaded argtype pts rt =
              (map (maybe (toStruct argtype) (Scalar . Prim)) pts,
               maybe (toStruct argtype) (Scalar . Prim) rt)

  checkNamedDim loc v = do
    (v', t) <- lookupVar loc v
    unify (mkUsage loc "use as array size") (toStruct t) $
      Scalar $ Prim $ Signed Int32
    return v'

checkQualNameWithEnv :: Namespace -> QualName Name -> SrcLoc -> TermTypeM (TermScope, QualName VName)
checkQualNameWithEnv space qn@(QualName quals name) loc = do
  scope <- asks termScope
  descend scope quals
  where descend scope []
          | Just name' <- M.lookup (space, name) $ scopeNameMap scope =
              return (scope, name')
          | otherwise =
              unknownVariableError space qn loc

        descend scope (q:qs)
          | Just (QualName _ q') <- M.lookup (Term, q) $ scopeNameMap scope,
            Just res <- M.lookup q' $ scopeModTable scope =
              case res of
                -- Check if we are referring to the magical intrinsics
                -- module.
                _ | baseTag q' <= maxIntrinsicTag ->
                      checkIntrinsic space qn loc
                ModEnv q_scope -> do
                  (scope', QualName qs' name') <- descend (envToTermScope q_scope) qs
                  return (scope', QualName (q':qs') name')
                ModFun{} -> unappliedFunctor loc
          | otherwise =
              unknownVariableError space qn loc

checkIntrinsic :: Namespace -> QualName Name -> SrcLoc -> TermTypeM (TermScope, QualName VName)
checkIntrinsic space qn@(QualName _ name) loc
  | Just v <- M.lookup (space, name) intrinsicsNameMap = do
      me <- liftTypeM askImportName
      unless ("/futlib" `isPrefixOf` includeToString me) $
        warn loc "Using intrinsic functions directly can easily crash the compiler or result in wrong code generation."
      scope <- asks termScope
      return (scope, v)
  | otherwise =
      unknownVariableError space qn loc

-- | Wrap 'Types.checkTypeDecl' to also perform an observation of
-- every size in the type.
checkTypeDecl :: TypeDeclBase NoInfo Name -> TermTypeM (TypeDeclBase Info VName)
checkTypeDecl tdecl = do
  (tdecl', _) <- Types.checkTypeDecl [] tdecl
  mapM_ observeDim $ nestedDims $ unInfo $ expandedType tdecl'
  return tdecl'
  where observeDim (NamedDim v) =
          observe $ Ident (qualLeaf v) (Info $ Scalar $ Prim $ Signed Int32) noLoc
        observeDim _ = return ()

-- | Instantiate a type scheme with fresh type variables for its type
-- parameters. Returns the names of the fresh type variables, the
-- instance list, and the instantiated type.
instantiateTypeScheme :: SrcLoc -> [TypeParam] -> PatternType
                      -> TermTypeM ([VName], PatternType)
instantiateTypeScheme loc tparams t = do
  let tnames = map typeParamName tparams
  (tparam_names, tparam_substs) <- unzip <$> mapM (instantiateTypeParam loc) tparams
  let substs = M.fromList $ zip tnames tparam_substs
      t' = substTypesAny (`M.lookup` substs) t
  return (tparam_names, t')

-- | Create a new type name and insert it (unconstrained) in the
-- substitution map.
instantiateTypeParam :: Monoid as => SrcLoc -> TypeParam -> TermTypeM (VName, Subst (TypeBase dim as))
instantiateTypeParam loc tparam = do
  i <- incCounter
  v <- newID $ mkTypeVarName (takeWhile isAscii (baseString (typeParamName tparam))) i
  case tparam of TypeParamType x _ _ -> do
                   constrain v $ NoConstraint x $ mkUsage' loc
                   return (v, Subst $ Scalar $ TypeVar mempty Nonunique (typeName v) [])
                 TypeParamDim{} -> do
                   constrain v $ Size Nothing $ mkUsage' loc
                   return (v, SizeSubst $ NamedDim $ qualName v)

newArrayType :: SrcLoc -> String -> Int -> TermTypeM (StructType, StructType)
newArrayType loc desc r = do
  v <- newID $ nameFromString desc
  constrain v $ NoConstraint Unlifted $ mkUsage' loc
  dims <- replicateM r $ newDimVar loc Nonrigid "dim"
  let rowt = TypeVar () Nonunique (typeName v) []
  return (Array () Nonunique rowt (ShapeDecl $ map (NamedDim . qualName) dims),
          Scalar rowt)

--- Errors

funName :: Maybe Name -> String
funName Nothing = "anonymous function"
funName (Just fname) = "function " ++ quote (pretty fname)

useAfterConsume :: MonadTypeChecker m => Name -> SrcLoc -> SrcLoc -> m a
useAfterConsume name rloc wloc =
  throwError $ TypeError rloc $
  "Variable " ++ quote (pretty name) ++ " previously consumed at " ++
  locStr wloc ++ ".  (Possibly through aliasing)"

consumeAfterConsume :: MonadTypeChecker m => Name -> SrcLoc -> SrcLoc -> m a
consumeAfterConsume name loc1 loc2 =
  throwError $ TypeError loc2 $
  "Variable " ++ pretty name ++ " previously consumed at " ++ locStr loc1 ++ "."

badLetWithValue :: MonadTypeChecker m => SrcLoc -> m a
badLetWithValue loc =
  throwError $ TypeError loc
  "New value for elements in let-with shares data with source array.  This is illegal, as it prevents in-place modification."

returnAliased :: MonadTypeChecker m => Maybe Name -> Name -> SrcLoc -> m ()
returnAliased fname name loc =
  throwError $ TypeError loc $
  "Unique return value of " ++ funName fname ++
  " is aliased to " ++ quote (pretty name) ++ ", which is not consumed."

uniqueReturnAliased :: MonadTypeChecker m => Maybe Name -> SrcLoc -> m a
uniqueReturnAliased fname loc =
  throwError $ TypeError loc $
  "A unique tuple element of return value of " ++
  funName fname ++ " is aliased to some other tuple component."

--- Basic checking

-- | Determine if the two types of identical, ignoring uniqueness.
-- Mismatched dimensions are turned into fresh rigid type variables.
-- Causes a 'TypeError' if they fail to match, and otherwise returns
-- one of them.
unifyBranchTypes :: SrcLoc -> PatternType -> PatternType -> TermTypeM (PatternType, [VName])
unifyBranchTypes loc e1_t e2_t =
  breadCrumb (Matching $
              "When matching the types of branches at " ++
              locStr loc ++ ".") $
  unifyMostCommon (mkUsage loc "unification of branch results") e1_t e2_t

unifyBranches :: SrcLoc -> Exp -> Exp -> TermTypeM (PatternType, [VName])
unifyBranches loc e1 e2 = do
  e1_t <- expType e1
  e2_t <- expType e2
  unifyBranchTypes loc e1_t e2_t

--- General binding.

doNotShadow :: [String]
doNotShadow = ["&&", "||"]

data InferredType = NoneInferred
                  | Ascribed PatternType


checkPattern' :: UncheckedPattern -> InferredType
              -> TermTypeM Pattern

checkPattern' (PatternParens p loc) t =
  PatternParens <$> checkPattern' p t <*> pure loc

checkPattern' (Id name _ loc) _
  | name' `elem` doNotShadow =
      typeError loc $ "The " ++ name' ++ " operator may not be redefined."
  where name' = nameToString name

checkPattern' (Id name NoInfo loc) (Ascribed t) = do
  name' <- newID name
  return $ Id name' (Info t) loc
checkPattern' (Id name NoInfo loc) NoneInferred = do
  name' <- newID name
  t <- newTypeVar loc "t"
  return $ Id name' (Info t) loc

checkPattern' (Wildcard _ loc) (Ascribed t) =
  return $ Wildcard (Info $ t `setUniqueness` Nonunique) loc
checkPattern' (Wildcard NoInfo loc) NoneInferred = do
  t <- newTypeVar loc "t"
  return $ Wildcard (Info t) loc

checkPattern' (TuplePattern ps loc) (Ascribed t)
  | Just ts <- isTupleRecord t, length ts == length ps =
      TuplePattern <$> zipWithM checkPattern' ps (map Ascribed ts) <*> pure loc
checkPattern' p@(TuplePattern ps loc) (Ascribed t) = do
  ps_t <- replicateM (length ps) (newTypeVar loc "t")
  unify (mkUsage loc "matching a tuple pattern") (tupleRecord ps_t) $ toStruct t
  t' <- normaliseType t
  checkPattern' p $ Ascribed t'
checkPattern' (TuplePattern ps loc) NoneInferred =
  TuplePattern <$> mapM (`checkPattern'` NoneInferred) ps <*> pure loc

checkPattern' (RecordPattern p_fs _) _
  | Just (f, fp) <- find (("_" `isPrefixOf`) . nameToString . fst) p_fs =
      typeError fp $ unlines [ "Underscore-prefixed fields are not allowed."
                             , "Did you mean " ++
                               quote (drop 1 (nameToString f) ++ "=_") ++ "?"]

checkPattern' (RecordPattern p_fs loc) (Ascribed (Scalar (Record t_fs)))
  | sort (map fst p_fs) == sort (M.keys t_fs) =
    RecordPattern . M.toList <$> check <*> pure loc
    where check = traverse (uncurry checkPattern') $ M.intersectionWith (,)
                  (M.fromList p_fs) (fmap Ascribed t_fs)
checkPattern' p@(RecordPattern fields loc) (Ascribed t) = do
  fields' <- traverse (const $ newTypeVar loc "t") $ M.fromList fields

  when (sort (M.keys fields') /= sort (map fst fields)) $
    typeError loc $ "Duplicate fields in record pattern " ++ pretty p

  unify (mkUsage loc "matching a record pattern") (Scalar (Record fields')) $ toStruct t
  t' <- normaliseType t
  checkPattern' p $ Ascribed t'
checkPattern' (RecordPattern fs loc) NoneInferred =
  RecordPattern . M.toList <$> traverse (`checkPattern'` NoneInferred) (M.fromList fs) <*> pure loc

checkPattern' (PatternAscription p (TypeDecl t NoInfo) loc) maybe_outer_t = do
  (t', st_nodims, _) <- checkTypeExp t
  (st, _) <- instantiateEmptyArrayDims loc "impl" Nonrigid st_nodims

  let st' = fromStruct st
  case maybe_outer_t of
    Ascribed outer_t -> do
      unify (mkUsage loc "explicit type ascription") (toStruct st) (toStruct outer_t)

      -- We also have to make sure that uniqueness matches.  This is
      -- done explicitly, because it is ignored by unification.
      st'' <- normaliseType st'
      outer_t' <- normaliseType outer_t
      case unifyTypesU unifyUniqueness st'' outer_t' of
        Just outer_t'' ->
          PatternAscription <$> checkPattern' p (Ascribed outer_t'') <*>
          pure (TypeDecl t' (Info st)) <*> pure loc
        Nothing ->
          typeError loc $ "Cannot match type " ++ quote (pretty outer_t') ++ " with expected type " ++
          quote (pretty st'') ++ "."

    NoneInferred ->
      PatternAscription <$> checkPattern' p (Ascribed st') <*>
      pure (TypeDecl t' (Info st)) <*> pure loc
 where unifyUniqueness u1 u2 = if u2 `subuniqueOf` u1 then Just u1 else Nothing

checkPattern' (PatternLit e NoInfo loc) (Ascribed t) = do
  e' <- checkExp e
  t' <- expType e'
  unify (mkUsage loc "matching against literal") (toStruct t') (toStruct t)
  return $ PatternLit e' (Info t') loc

checkPattern' (PatternLit e NoInfo loc) NoneInferred = do
  e' <- checkExp e
  t' <- expType e'
  return $ PatternLit e' (Info t') loc

checkPattern' (PatternConstr n NoInfo ps loc) (Ascribed (Scalar (Sum cs)))
  | Just ts <- M.lookup n cs = do
      ps' <- zipWithM checkPattern' ps $ map Ascribed ts
      return $ PatternConstr n (Info (Scalar (Sum cs))) ps' loc

checkPattern' (PatternConstr n NoInfo ps loc) (Ascribed t) = do
  t' <- newTypeVar loc "t"
  ps' <- mapM (`checkPattern'` NoneInferred) ps
  mustHaveConstr usage n t' (patternStructType <$> ps')
  unify usage t' (toStruct t)
  t'' <- normaliseType t
  return $ PatternConstr n (Info t'') ps' loc
  where usage = mkUsage loc "matching against constructor"

checkPattern' (PatternConstr n NoInfo ps loc) NoneInferred = do
  ps' <- mapM (`checkPattern'` NoneInferred) ps
  t <- newTypeVar loc "t"
  mustHaveConstr usage n t (patternStructType <$> ps')
  return $ PatternConstr n (Info $ fromStruct t) ps' loc
  where usage = mkUsage loc "matching against constructor"

patternNameMap :: Pattern -> NameMap
patternNameMap = M.fromList . map asTerm . S.toList . patternIdents
  where asTerm v = ((Term, baseName $ identName v), qualName $ identName v)

checkPattern :: UncheckedPattern -> InferredType -> (Pattern -> TermTypeM a)
             -> TermTypeM a
checkPattern p t m = do
  checkForDuplicateNames [p]
  p' <- checkPattern' p t
  bindNameMap (patternNameMap p') $ m p'

binding :: [Ident] -> TermTypeM a -> TermTypeM a
binding bnds = check . handleVars
  where handleVars m =
          localScope (`bindVars` bnds) $ do

          -- Those identifiers that can potentially also be sizes are
          -- added as type constraints.  This is necessary so that we
          -- can properly detect scope violations during unification.
          -- We do this for *all* identifiers, not just those that are
          -- integers, because they may become integers later due to
          -- inference...
          forM_ bnds $ \ident ->
            constrain (identName ident) $ ParamSize $ srclocOf ident
          m

        bindVars :: TermScope -> [Ident] -> TermScope
        bindVars = foldl bindVar

        bindVar :: TermScope -> Ident -> TermScope
        bindVar scope (Ident name (Info tp) _) =
          let inedges = boundAliases $ aliases tp
              update (BoundV l tparams in_t)
                -- If 'name' is record or sum-typed, don't alias the
                -- components to 'name', because these no identity
                -- beyond their components.
                | Array{} <- tp = BoundV l tparams (in_t `addAliases` S.insert (AliasBound name))
                | otherwise = BoundV l tparams in_t
              update b = b

              tp' = tp `addAliases` S.insert (AliasBound name)
          in scope { scopeVtable = M.insert name (BoundV Local [] tp') $
                                   adjustSeveral update inedges $
                                   scopeVtable scope
                   }

        adjustSeveral f = flip $ foldl $ flip $ M.adjust f

        -- Check whether the bound variables have been used correctly
        -- within their scope.
        check m = do
          (a, usages) <- collectBindingsOccurences m
          checkOccurences usages

          mapM_ (checkIfUsed usages) bnds

          return a

        -- Collect and remove all occurences in @bnds@.  This relies
        -- on the fact that no variables shadow any other.
        collectBindingsOccurences m = pass $ do
          (x, usage) <- listen m
          let (relevant, rest) = split usage
          return ((x, relevant), const rest)
          where split = unzip .
                        map (\occ ->
                             let (obs1, obs2) = divide $ observed occ
                                 occ_cons = divide <$> consumed occ
                                 con1 = fst <$> occ_cons
                                 con2 = snd <$> occ_cons
                             in (occ { observed = obs1, consumed = con1 },
                                 occ { observed = obs2, consumed = con2 }))
                names = S.fromList $ map identName bnds
                divide s = (s `S.intersection` names, s `S.difference` names)

bindingTypes :: [Either (VName, TypeBinding) (VName, Constraint)]
             -> TermTypeM a -> TermTypeM a
bindingTypes types m = do
  lvl <- curLevel
  modifyConstraints (<>M.map (lvl,) (M.fromList constraints))
  localScope extend m
  where (tbinds, constraints) = partitionEithers types
        extend scope = scope {
          scopeTypeTable = M.fromList tbinds <> scopeTypeTable scope
          }

bindingTypeParams :: [TypeParam] -> TermTypeM a -> TermTypeM a
bindingTypeParams tparams = binding (mapMaybe typeParamIdent tparams) .
                            bindingTypes (concatMap typeParamType tparams)
  where typeParamType (TypeParamType l v loc) =
          [ Left (v, TypeAbbr l [] (Scalar (TypeVar () Nonunique (typeName v) [])))
          , Right (v, ParamType l loc) ]
        typeParamType (TypeParamDim v loc) =
          [ Right (v, ParamSize loc) ]

typeParamIdent :: TypeParam -> Maybe Ident
typeParamIdent (TypeParamDim v loc) =
  Just $ Ident v (Info $ Scalar $ Prim $ Signed Int32) loc
typeParamIdent _ = Nothing

bindingIdent :: IdentBase NoInfo Name -> PatternType -> (Ident -> TermTypeM a)
             -> TermTypeM a
bindingIdent (Ident v NoInfo vloc) t m =
  bindSpaced [(Term, v)] $ do
    v' <- checkName Term v vloc
    let ident = Ident v' (Info t) vloc
    binding [ident] $ m ident

bindingParams :: [UncheckedTypeParam]
              -> [UncheckedPattern]
              -> ([TypeParam] -> [Pattern] -> TermTypeM a) -> TermTypeM a
bindingParams tps orig_ps m = do
  checkForDuplicateNames orig_ps
  checkTypeParams tps $ \tps' -> bindingTypeParams tps' $ do
    let descend ps' (p:ps) =
          checkPattern p NoneInferred $ \p' ->
            binding (S.toList $ patternIdents p') $ descend (p':ps') ps
        descend ps' [] = do
          -- Perform an observation of every type parameter.  This
          -- prevents unused-name warnings for otherwise unused
          -- dimensions.
          mapM_ observe $ mapMaybe typeParamIdent tps'
          let ps'' = reverse ps'
          checkShapeParamUses patternUses tps' ps''

          m tps' ps''

    descend [] orig_ps

bindingPattern :: PatternBase NoInfo Name -> InferredType
               -> (Pattern -> TermTypeM a) -> TermTypeM a
bindingPattern p t m = do
  checkForDuplicateNames [p]
  checkPattern p t $ \p' -> binding (S.toList $ patternIdents p') $ do
    -- Perform an observation of every declared dimension.  This
    -- prevents unused-name warnings for otherwise unused dimensions.
    mapM_ observe $ patternDims p'

    m p'

-- | Return the shapes used in a given pattern in postive and negative
-- position, respectively.
patternUses :: Pattern -> ([VName], [VName])
patternUses Id{} = mempty
patternUses Wildcard{} = mempty
patternUses PatternLit{} = mempty
patternUses (PatternParens p _) = patternUses p
patternUses (TuplePattern ps _) = foldMap patternUses ps
patternUses (RecordPattern fs _) = foldMap (patternUses . snd) fs
patternUses (PatternAscription p (TypeDecl declte _) _) =
  patternUses p <> typeExpUses declte
patternUses (PatternConstr _ _ ps _) = foldMap patternUses ps

patternDims :: Pattern -> [Ident]
patternDims (PatternParens p _) = patternDims p
patternDims (TuplePattern pats _) = concatMap patternDims pats
patternDims (PatternAscription p (TypeDecl _ (Info t)) _) =
  patternDims p <> mapMaybe (dimIdent (srclocOf p)) (nestedDims t)
  where dimIdent _ AnyDim            = Nothing
        dimIdent _ (ConstDim _)      = Nothing
        dimIdent _ NamedDim{}        = Nothing
patternDims _ = []

sliceShape :: Maybe (SrcLoc, Rigidity) -> [DimIndex] -> TypeBase (DimDecl VName) as
           -> TermTypeM (TypeBase (DimDecl VName) as, [VName])
sliceShape r slice t@(Array als u et (ShapeDecl orig_dims)) =
  runWriterT $ setDims <$> adjustDims slice orig_dims
  where setDims []    = stripArray (length orig_dims) t
        setDims dims' = Array als u et $ ShapeDecl dims'

        -- If the result is supposed to be AnyDim or a nonrigid size
        -- variable, then don't bother trying to create
        -- non-existential sizes.  This is necessary to make programs
        -- type-check without too much ceremony; see
        -- e.g. tests/inplace5.fut.
        refine_sizes = maybe False ((==Rigid) . snd) r

        sliceSize orig_d i j stride =
          case r of
            Just (loc, Rigid) -> do
              (d, ext) <-
                lift $ extSize loc $
                SourceSlice orig_d' (bareExp <$> i) (bareExp <$> j) (bareExp <$> stride)
              tell $ maybeToList ext
              return d
            Just (loc, Nonrigid) ->
              lift $ NamedDim . qualName <$> newDimVar loc Nonrigid "slice_dim"
            Nothing ->
              pure AnyDim
          where
            -- The original size does not matter if the slice is fully specified.
            orig_d' | isJust i, isJust j = Nothing
                    | otherwise = Just orig_d

        adjustDims (DimFix{} : idxes') (_:dims) =
          adjustDims idxes' dims

        -- Pattern match some known slices to be non-existential.
        adjustDims (DimSlice i j stride : idxes') (_:dims)
          | refine_sizes,
            maybe True ((==Just 0) . isInt32) i,
            Just j' <- maybeDimFromArg =<< j,
            maybe True ((==Just 1) . isInt32) stride =
              (j':) <$> adjustDims idxes' dims

        adjustDims (DimSlice Nothing Nothing stride : idxes') (d:dims)
          | refine_sizes,
            maybe True (maybe False ((==1) . abs) . isInt32) stride =
              (d:) <$> adjustDims idxes' dims

        adjustDims (DimSlice i j stride : idxes') (d:dims) =
          (:) <$> sliceSize d i j stride <*> adjustDims idxes' dims

        adjustDims _ dims =
          pure dims

sliceShape _ _ t = pure (t, [])

--- Main checkers

-- | @require ts e@ causes a 'TypeError' if @expType e@ is not one of
-- the types in @ts@.  Otherwise, simply returns @e@.
require :: String -> [PrimType] -> Exp -> TermTypeM Exp
require why ts e = do mustBeOneOf ts (mkUsage (srclocOf e) why) . toStruct =<< expType e
                      return e

unifies :: String -> StructType -> Exp -> TermTypeM Exp
unifies why t e = do
  unify (mkUsage (srclocOf e) why) t =<< toStruct <$> expType e
  return e

-- The closure of a lambda or local function are those variables that
-- it references, and which local to the current top-level function.
lexicalClosure :: [Pattern] -> Occurences -> TermTypeM Aliasing
lexicalClosure params closure = do
  vtable <- asks $ scopeVtable . termScope
  let isLocal v = case v `M.lookup` vtable of
                    Just (BoundV Local _ _) -> True
                    _ -> False
  return $ S.map AliasBound $ S.filter isLocal $
    allOccuring closure S.\\
    S.map identName (mconcat (map patternIdents params))

checkExp :: UncheckedExp -> TermTypeM Exp

checkExp (Literal val loc) =
  return $ Literal val loc

checkExp (StringLit vs loc) =
  return $ StringLit vs loc

checkExp (IntLit val NoInfo loc) = do
  t <- newTypeVar loc "t"
  mustBeOneOf anyNumberType (mkUsage loc "integer literal") t
  return $ IntLit val (Info $ fromStruct t) loc

checkExp (FloatLit val NoInfo loc) = do
  t <- newTypeVar loc "t"
  mustBeOneOf anyFloatType (mkUsage loc "float literal") t
  return $ FloatLit val (Info $ fromStruct t) loc

checkExp (TupLit es loc) =
  TupLit <$> mapM checkExp es <*> pure loc

checkExp (RecordLit fs loc) = do
  fs' <- evalStateT (mapM checkField fs) mempty

  return $ RecordLit fs' loc
  where checkField (RecordFieldExplicit f e rloc) = do
          errIfAlreadySet f rloc
          modify $ M.insert f rloc
          RecordFieldExplicit f <$> lift (checkExp e) <*> pure rloc
        checkField (RecordFieldImplicit name NoInfo rloc) = do
          errIfAlreadySet name rloc
          (QualName _ name', t) <- lift $ lookupVar rloc $ qualName name
          modify $ M.insert name rloc
          return $ RecordFieldImplicit name' (Info t) rloc

        errIfAlreadySet f rloc = do
          maybe_sloc <- gets $ M.lookup f
          case maybe_sloc of
            Just sloc ->
              lift $ typeError rloc $ "Field '" ++ pretty f ++
              " previously defined at " ++ locStr sloc ++ "."
            Nothing -> return ()

checkExp (ArrayLit all_es _ loc) =
  -- Construct the result type and unify all elements with it.  We
  -- only create a type variable for empty arrays; otherwise we use
  -- the type of the first element.  This significantly cuts down on
  -- the number of type variables generated for pathologically large
  -- multidimensional array literals.
  case all_es of
    [] -> do et <- newTypeVar loc "t"
             t <- arrayOfM loc et (ShapeDecl [ConstDim 0]) Unique
             return $ ArrayLit [] (Info t) loc
    e:es -> do
      e' <- checkExp e
      et <- expType e'
      es' <- mapM (unifies "type of first array element" (toStruct et) <=< checkExp) es
      et' <- normaliseType et
      t <- arrayOfM loc et' (ShapeDecl [ConstDim $ length all_es]) Unique
      return $ ArrayLit (e':es') (Info t) loc

checkExp (Range start maybe_step end _ loc) = do
  start' <- require "use in range expression" anyIntType =<< checkExp start
  start_t <- toStruct <$> expType start'
  maybe_step' <- case maybe_step of
    Nothing -> return Nothing
    Just step -> do
      let warning = warn loc "First and second element of range are identical, this will produce an empty array."
      case (start, step) of
        (Literal x _, Literal y _) -> when (x == y) warning
        (Var x_name _ _, Var y_name _ _) -> when (x_name == y_name) warning
        _ -> return ()
      Just <$> (unifies "use in range expression" start_t =<< checkExp step)

  let unifyRange e = unifies "use in range expression" start_t =<< checkExp e
  end' <- case end of
    DownToExclusive e -> DownToExclusive <$> unifyRange e
    UpToExclusive e -> UpToExclusive <$> unifyRange e
    ToInclusive e -> ToInclusive <$> unifyRange e

  -- Special case some ranges to give them a known size.
  (dim, retext) <-
    case (isInt32 start', isInt32 <$> maybe_step', end') of
      (Just 0, Just (Just 1), UpToExclusive end'') ->
        dimFromArg end''
      (Just 0, Nothing, UpToExclusive end'') ->
        dimFromArg end''
      (Just 1, Just (Just 2), ToInclusive end'') ->
        dimFromArg end''
      _ -> do
        d <- newDimVar loc Rigid "range_dim"
        return (NamedDim $ qualName d, Just d)

  t <- arrayOfM loc start_t (ShapeDecl [dim]) Unique
  let ret = (Info (t `setAliases` mempty), Info $ maybeToList retext)

  return $ Range start' maybe_step' end' ret loc

checkExp (Ascript e decl _ loc) = do
  decl' <- checkTypeDecl decl
  e' <- checkExp e
  t <- expType e'

  -- We instantiate the declared types with all dimensions as nonrigid
  -- fresh type variables, which we then use to unify with the type of
  -- 'e'.  This lets 'e' have whatever sizes it wants, but the overall
  -- type must still match.  Eventually we will throw away those sizes
  -- (they will end up being unified with various sizes in 'e', which
  -- is fine).
  (decl_t_nonrigid, _) <-
    instantiateEmptyArrayDims loc "impl" Nonrigid $ anyDimShapeAnnotations $
    unInfo $ expandedType decl'
  unify (mkUsage loc "explicit type ascription")
    (toStruct decl_t_nonrigid) (toStruct t)

  -- We also have to make sure that uniqueness matches.  This is done
  -- explicitly, because uniqueness is ignored by unification.
  t' <- normaliseType t
  decl_t' <- normaliseType $ unInfo $ expandedType decl'
  unless (t' `subtypeOf` anyDimShapeAnnotations decl_t') $
    typeError loc $ "Type " ++ quote (pretty t') ++ " is not a subtype of " ++
    quote (pretty decl_t') ++ "."

  -- Now we instantiate the declared type again, but this time we keep
  -- around the sizes as existentials.  This is the result of the
  -- ascription as a whole.  We use matchDims to obtain the aliasing
  -- of 'e'.
  (decl_t_rigid, ext) <-
    instantiateDimsInReturnType loc decl_t'

  t'' <- matchDims (const pure) t' $ fromStruct decl_t_rigid

  return $ Ascript e' decl' (Info t'', Info ext) loc

checkExp (BinOp (op, oploc) NoInfo (e1,_) (e2,_) NoInfo NoInfo loc) = do
  (op', ftype) <- lookupVar oploc op
  e1_arg <- checkArg e1
  e2_arg <- checkArg e2

  -- Note that the application to the first operand cannot fix any
  -- existential sizes, because it must by necessity be a function.
  (p1_t, rt, p1_ext, _) <- checkApply loc ftype e1_arg
  (p2_t, rt', p2_ext, retext) <- checkApply loc rt e2_arg

  return $ BinOp (op', oploc) (Info ftype)
    (argExp e1_arg, Info (toStruct p1_t, p1_ext))
    (argExp e2_arg, Info (toStruct p2_t, p2_ext))
    (Info rt') (Info retext) loc

checkExp (Project k e NoInfo loc) = do
  e' <- checkExp e
  t <- expType e'
  kt <- mustHaveField (mkUsage loc $ "projection of field " ++ quote (pretty k)) k t
  return $ Project k e' (Info kt) loc

checkExp (If e1 e2 e3 _ loc) =
  sequentially checkCond $ \e1' _ -> do
  ((e2', e3'), dflow) <- tapOccurences $ checkExp e2 `alternative` checkExp e3

  (brancht, retext) <- unifyBranches loc e2' e3'
  let t' = addAliases brancht (`S.difference` S.map AliasBound (allConsumed dflow))

  zeroOrderType (mkUsage loc "returning value of this type from 'if' expression")
    "returned from branch" t'

  return $ If e1' e2' e3' (Info t', Info retext) loc

  where checkCond = do
          e1' <- checkExp e1
          unify (mkUsage (srclocOf e1') "use as 'if' condition")
            (Scalar $ Prim Bool) . toStruct =<< expType e1'
          return e1'

checkExp (Parens e loc) =
  Parens <$> checkExp e <*> pure loc

checkExp (QualParens (modname, modnameloc) e loc) = do
  (modname',mod) <- lookupMod loc modname
  case mod of
    ModEnv env -> local (`withEnv` qualifyEnv modname' env) $ do
      e' <- checkExp e
      return $ QualParens (modname', modnameloc) e' loc
    ModFun{} ->
      typeError loc $ "Module " ++ pretty modname ++ " is a parametric module."
  where qualifyEnv modname' env =
          env { envNameMap = M.map (qualify' modname') $ envNameMap env }
        qualify' modname' (QualName qs name) =
          QualName (qualQuals modname' ++ [qualLeaf modname'] ++ qs) name

checkExp (Var qn NoInfo loc) = do
  -- The qualifiers of a variable is divided into two parts: first a
  -- possibly-empty sequence of module qualifiers, followed by a
  -- possible-empty sequence of record field accesses.  We use scope
  -- information to perform the split, by taking qualifiers off the
  -- end until we find a module.

  (qn', t, fields) <- findRootVar (qualQuals qn) (qualLeaf qn)

  foldM checkField (Var qn' (Info t) loc) fields

  where findRootVar qs name =
          (whenFound <$> lookupVar loc (QualName qs name)) `catchError` notFound qs name

        whenFound (qn', t) = (qn', t, [])

        notFound qs name err
          | null qs = throwError err
          | otherwise = do
              (qn', t, fields) <- findRootVar (init qs) (last qs) `catchError`
                                  const (throwError err)
              return (qn', t, fields++[name])

        checkField e k = do
          t <- expType e
          let usage = mkUsage loc $ "projection of field " ++ quote (pretty k)
          kt <- mustHaveField usage k t
          return $ Project k e (Info kt) loc

checkExp (Negate arg loc) = do
  arg' <- require "numeric negation" anyNumberType =<< checkExp arg
  return $ Negate arg' loc

checkExp (Apply e1 e2 _ _ loc) = do
  e1' <- checkExp e1
  arg <- checkArg e2
  t <- expType e1'
  (t1, rt, argext, exts) <- checkApply loc t arg
  return $ Apply e1' (argExp arg) (Info (diet t1, argext)) (Info rt, Info exts) loc

checkExp (LetPat pat e body _ loc) =
  sequentially (checkExp e) $ \e' e_occs -> do
    -- Not technically an ascription, but we want the pattern to have
    -- exactly the type of 'e'.
    t <- expType e'
    case anyConsumption e_occs of
      Just c ->
        let msg = "of value computed with consumption at " ++ locStr (location c)
        in zeroOrderType (mkUsage loc "consumption in right-hand side of 'let'-binding") msg t
      _ -> return ()

    incLevel $ bindingPattern pat (Ascribed t) $ \pat' -> do
      body' <- checkExp body
      (body_t, retext) <-
        instantiateDimsInReturnType loc .
        unscopeType (S.map identName $ patternIdents pat')
        =<< expType body'

      return $ LetPat pat' e' body' (Info body_t, Info retext) loc

checkExp (LetFun name (tparams, params, maybe_retdecl, NoInfo, e) body loc) =
  sequentially (checkBinding (Just name, maybe_retdecl, tparams, params, e, loc)) $
  \(tparams', params', maybe_retdecl', rettype, _, e') closure -> do

    closure' <- lexicalClosure params' closure

    bindSpaced [(Term, name)] $ do
      name' <- checkName Term name loc

      let arrow (xp, xt) yt = Scalar $ Arrow () xp xt yt
          ftype = foldr (arrow . patternParam) rettype params'
          entry = BoundV Local tparams' $ ftype `setAliases` closure'
          bindF scope = scope { scopeVtable = M.insert name' entry $ scopeVtable scope
                              , scopeNameMap = M.insert (Term, name) (qualName name') $
                                               scopeNameMap scope }
      body' <- localScope bindF $ checkExp body

      return $ LetFun name' (tparams', params', maybe_retdecl', Info rettype, e') body' loc

checkExp (LetWith dest src idxes ve body NoInfo loc) =
  sequentially (checkIdent src) $ \src' _ -> do
  (t, _) <- newArrayType (srclocOf src) "src" $ length idxes
  unify (mkUsage loc "type of target array") t $ toStruct $ unInfo $ identType src'
  idxes' <- mapM checkDimIndex idxes
  (elemt, _) <- sliceShape (Just (loc, Nonrigid)) idxes' =<< normaliseType t

  unless (unique $ unInfo $ identType src') $
    typeError loc $ "Source " ++ quote (pretty (identName src)) ++
    " has type " ++ pretty (unInfo $ identType src') ++ ", which is not unique."
  vtable <- asks $ scopeVtable . termScope
  forM_ (aliases $ unInfo $ identType src') $ \v ->
    case aliasVar v `M.lookup` vtable of
      Just (BoundV Local _ v_t)
        | not $ unique v_t ->
            typeError loc $ "Source " ++ quote (pretty (identName src)) ++
            " aliases " ++ quote (prettyName (aliasVar v)) ++ ", which is not consumable."
      _ -> return ()

  sequentially (unifies "type of target array" (toStruct elemt) =<< checkExp ve) $ \ve' _ -> do
    ve_t <- expType ve'
    when (AliasBound (identName src') `S.member` aliases ve_t) $
      badLetWithValue loc

    bindingIdent dest (unInfo (identType src') `setAliases` S.empty) $ \dest' -> do
      body' <- consuming src' $ checkExp body
      body_t <- unscopeType (S.singleton $ identName dest') <$> expType body'
      return $ LetWith dest' src' idxes' ve' body' (Info body_t) loc

checkExp (Update src idxes ve loc) = do
  (t, _) <- newArrayType (srclocOf src) "src" $ length idxes
  idxes' <- mapM checkDimIndex idxes
  (elemt, _) <- sliceShape (Just (loc, Nonrigid)) idxes' =<< normaliseType t

  sequentially (checkExp ve >>= unifies "type of target array" elemt) $ \ve' _ ->
    sequentially (checkExp src >>= unifies "type of target array" t) $ \src' _ -> do

    src_t <- expType src'
    unless (unique src_t) $
      typeError loc $ "Source " ++ quote (pretty src) ++
      " has type " ++ pretty src_t ++ ", which is not unique"

    let src_als = aliases src_t
    ve_t <- expType ve'
    unless (S.null $ src_als `S.intersection` aliases ve_t) $ badLetWithValue loc

    consume loc src_als
    return $ Update src' idxes' ve' loc

-- Record updates are a bit hacky, because we do not have row typing
-- (yet?).  For now, we only permit record updates where we know the
-- full type up to the field we are updating.
checkExp (RecordUpdate src fields ve NoInfo loc) = do
  src' <- checkExp src
  ve' <- checkExp ve
  a <- expType src'
  let usage = mkUsage loc "record update"
  r <- foldM (flip $ mustHaveField usage) a fields
  ve_t <- expType ve'
  unify usage (anyDimShapeAnnotations $ toStruct r)
              (anyDimShapeAnnotations $ toStruct ve_t)
  maybe_a' <- onRecordField (const ve_t) fields <$> expType src'
  case maybe_a' of
    Just a' -> return $ RecordUpdate src' fields ve' (Info a') loc
    Nothing -> typeError loc $ pretty $
               text "Full type of" </>
               indent 2 (ppr src) </>
               text " is not known at this point.  Add a size annotation to the original record to disambiguate."

checkExp (Index e idxes _ loc) = do
  (t, _) <- newArrayType loc "e" $ length idxes
  e' <- unifies "being indexed at" t =<< checkExp e
  idxes' <- mapM checkDimIndex idxes
  (t', retext) <- sliceShape (Just (loc, Rigid)) idxes' =<< normaliseType (typeOf e')
  return $ Index e' idxes' (Info t', Info retext) loc

checkExp (Unsafe e loc) =
  Unsafe <$> checkExp e <*> pure loc

checkExp (Assert e1 e2 NoInfo loc) = do
  e1' <- require "being asserted" [Bool] =<< checkExp e1
  e2' <- checkExp e2
  return $ Assert e1' e2' (Info (pretty e1)) loc

checkExp (Lambda params body rettype_te NoInfo loc) =
  removeSeminullOccurences $ incLevel $
  bindingParams [] params $ \_ params' -> do
    rettype_checked <- traverse checkTypeExp rettype_te
    let declared_rettype =
          case rettype_checked of Just (_, st, _) -> Just st
                                  Nothing -> Nothing
    (body', closure) <-
      tapOccurences $ noUnique $ checkFunBody params' body declared_rettype loc
    body_t <- expType body'

    params'' <- mapM updateTypes params'

    (rettype', rettype_st) <-
      case rettype_checked of
        Just (te, st, _) ->
          return (Just te, st)
        Nothing -> do
          ret <- inferReturnSizes params'' $
                 inferReturnUniqueness params'' body_t
          return (Nothing, ret)

    checkGlobalAliases params' body_t loc
    verifyFunctionParams params'

    closure' <- lexicalClosure params'' closure

    return $ Lambda params'' body' rettype' (Info (closure', rettype_st)) loc

  where
    -- Inferring the sizes of the return type of a lambda is a lot
    -- like let-generalisation.  We wish to remove any rigid sizes
    -- that were created when checking the body, except for those that
    -- are visible in types that existed before we entered the body,
    -- are parameters, or are used in parameters.
    inferReturnSizes params' ret = do
      cur_lvl <- curLevel
      let named (Named x, _) = Just x
          named (Unnamed, _) = Nothing
          param_names = mapMaybe (named . patternParam) params'
          pos_sizes =
            typeDimNamesPos (foldFunType (map patternStructType params') ret)
          hide k (lvl, _) =
            lvl >= cur_lvl && k `notElem` param_names && k `S.notMember` pos_sizes

      hidden_sizes <-
        S.fromList . M.keys . M.filterWithKey hide <$> getConstraints

      let onDim (NamedDim name)
            | not (qualLeaf name `S.member` hidden_sizes) = NamedDim name
            | otherwise = AnyDim
          onDim d = d

      return $ first onDim ret

checkExp (OpSection op _ loc) = do
  (op', ftype) <- lookupVar loc op
  return $ OpSection op' (Info ftype) loc

checkExp (OpSectionLeft op _ e _ _ loc) = do
  (op', ftype) <- lookupVar loc op
  e_arg <- checkArg e
  (t1, rt, argext, retext) <- checkApply loc ftype e_arg
  case rt of
    Scalar (Arrow _ _ t2 rettype) ->
      return $ OpSectionLeft op' (Info ftype) (argExp e_arg)
      (Info (toStruct t1, argext), Info $ toStruct t2) (Info rettype, Info retext) loc
    _ -> typeError loc $
         "Operator section with invalid operator of type " ++ pretty ftype

checkExp (OpSectionRight op _ e _ NoInfo loc) = do
  (op', ftype) <- lookupVar loc op
  e_arg <- checkArg e
  case ftype of
    Scalar (Arrow as1 m1 t1 (Scalar (Arrow as2 m2 t2 ret))) -> do
      (t2', Scalar (Arrow _ _ t1' rettype), argext, _) <-
        checkApply loc (Scalar $ Arrow as2 m2 t2 $ Scalar $ Arrow as1 m1 t1 ret) e_arg
      return $ OpSectionRight op' (Info ftype) (argExp e_arg)
        (Info $ toStruct t1', Info (toStruct t2', argext)) (Info rettype) loc
    _ -> typeError loc $
         "Operator section with invalid operator of type " ++ pretty ftype

checkExp (ProjectSection fields NoInfo loc) = do
  a <- newTypeVar loc "a"
  let usage = mkUsage loc "projection at"
  b <- foldM (flip $ mustHaveField usage) a fields
  return $ ProjectSection fields (Info $ Scalar $ Arrow mempty Unnamed a b) loc

checkExp (IndexSection idxes NoInfo loc) = do
  (t, _) <- newArrayType loc "e" $ length idxes
  idxes' <- mapM checkDimIndex idxes
  (t', _) <- sliceShape Nothing idxes' t
  return $ IndexSection idxes' (Info $ fromStruct $ Scalar $ Arrow mempty Unnamed t t') loc

checkExp (DoLoop _ mergepat mergeexp form loopbody NoInfo loc) =
  sequentially (checkExp mergeexp) $ \mergeexp' _ -> do

  zeroOrderType (mkUsage (srclocOf mergeexp) "use as loop variable")
    "used as loop variable" (typeOf mergeexp')

  -- The handling of dimension sizes is a bit intricate, but very
  -- similar to checking a function, followed by checking a call to
  -- it.  The overall procedure is as follows:
  --
  -- (1) All empty dimensions in the merge pattern are instantiated
  -- with nonrigid size variables.  All explicitly specified
  -- dimensions are preserved.
  --
  -- (2) The body of the loop is type-checked.  The result type is
  -- combined with the merge pattern type to determine which sizes are
  -- variant, and these are turned into size parameters for the merge
  -- pattern.
  --
  -- (3) We now conceptually have a function parameter type and return
  -- type.  We check that it can be called with the initial merge
  -- values as argument.  The result of this is the type of the loop
  -- as a whole.
  --
  -- (There is also a convergence loop for inferring uniqueness, but
  -- that's orthogonal to the size handling.)

  (merge_t, new_dims) <-
    instantiateEmptyArrayDims loc "loop" Nonrigid . -- dim handling (1)
    anyDimShapeAnnotations .
    (`setAliases` mempty) =<< expType mergeexp'

  -- dim handling (2)
  let checkLoopReturnSize mergepat' loopbody' = do
        loopbody_t <- expType loopbody'
        pat_t <- normaliseType $ patternType mergepat'
        -- We are ignoring the dimensions here, because any mismatches
        -- should be turned into fresh size variables.
        unify (mkUsage (srclocOf loopbody) "matching loop body to loop pattern")
          (toStruct (anyDimShapeAnnotations pat_t))
          (toStruct (anyDimShapeAnnotations loopbody_t))
        pat_t' <- normaliseType pat_t
        loopbody_t' <- normaliseType loopbody_t

        -- For each new_dims, figure out what they are instantiated
        -- with in the initial value.  This is used to determine
        -- whether a size is invariant because it always matches the
        -- initial instantiation of that size.
        let initSubst (NamedDim v, d) = Just (v, d)
            initSubst _ = Nothing
        init_substs <- M.fromList . mapMaybe initSubst . snd .
                       anyDimOnMismatch pat_t' <$>
                       expType mergeexp'

        -- Figure out which of the 'new_dims' dimensions are variant.
        -- This works because we know that each dimension from
        -- new_dims in the pattern is unique and distinct.
        --
        -- Our logic here is a bit reversed: the *mismatches* (from
        -- new_dims) are what we want to extract and turn into size
        -- parameters.
        let mismatchSubst (NamedDim v, d)
              | qualLeaf v `elem` new_dims =
                  case M.lookup v init_substs of
                    Just d'
                      | d' == d ->
                          return $ Just (qualLeaf v, SizeSubst d)
                    _ -> do tell [qualLeaf v]
                            return Nothing
            mismatchSubst _ = return Nothing

            (init_substs', sparams) =
              runWriter $ M.fromList . catMaybes <$> mapM mismatchSubst
              (snd $ anyDimOnMismatch pat_t loopbody_t')

        -- Make sure that any of new_dims that are invariant will be
        -- replaced with the invariant size in the loop body.  Failure
        -- to do this can cause type annotations to still refer to
        -- new_dims.
        let dimToInit (v, SizeSubst d) =
              constrain v $ Size (Just d) (mkUsage loc "size of loop parameter")
            dimToInit _ =
              return ()
        mapM_ dimToInit $ M.toList init_substs'

        mergepat'' <- applySubst (`M.lookup` init_substs') <$> updateTypes mergepat'
        return (nub sparams, mergepat'')

  -- First we do a basic check of the loop body to figure out which of
  -- the merge parameters are being consumed.  For this, we first need
  -- to check the merge pattern, which requires the (initial) merge
  -- expression.
  --
  -- Play a little with occurences to ensure it does not look like
  -- none of the merge variables are being used.
  ((sparams, mergepat', form', loopbody'), bodyflow) <-
    case form of
      For i uboundexp -> do
        uboundexp' <- require "being the bound in a 'for' loop" anySignedType =<< checkExp uboundexp
        bound_t <- expType uboundexp'
        bindingIdent i bound_t $ \i' ->
          noUnique $ bindingPattern mergepat (Ascribed merge_t) $
          \mergepat' -> onlySelfAliasing $ tapOccurences $ do
            loopbody' <- checkExp loopbody
            (sparams, mergepat'') <- checkLoopReturnSize mergepat' loopbody'
            return (sparams,
                    mergepat'',
                    For i' uboundexp',
                    loopbody')

      ForIn xpat e -> do
        (arr_t, _) <- newArrayType (srclocOf e) "e" 1
        e' <- unifies "being iterated in a 'for-in' loop" arr_t =<< checkExp e
        t <- expType e'
        case t of
          _ | Just t' <- peelArray 1 t ->
                bindingPattern xpat (Ascribed t') $ \xpat' ->
                noUnique $ bindingPattern mergepat (Ascribed merge_t) $
                \mergepat' -> onlySelfAliasing $ tapOccurences $ do
                  loopbody' <- checkExp loopbody
                  (sparams, mergepat'') <- checkLoopReturnSize mergepat' loopbody'
                  return (sparams,
                          mergepat'',
                          ForIn xpat' e',
                          loopbody')
            | otherwise ->
                typeError (srclocOf e) $
                "Iteratee of a for-in loop must be an array, but expression has type " ++ pretty t

      While cond ->
        noUnique $ bindingPattern mergepat (Ascribed merge_t) $ \mergepat' ->
        onlySelfAliasing $ tapOccurences $
        sequentially (checkExp cond >>=
                      unifies "being the condition of a 'while' loop" (Scalar $ Prim Bool)) $ \cond' _ -> do
          loopbody' <- checkExp loopbody
          (sparams, mergepat'') <- checkLoopReturnSize mergepat' loopbody'
          return (sparams,
                  mergepat'',
                  While cond',
                  loopbody')

  mergepat'' <- do
    loop_t <- expType loopbody'
    convergePattern mergepat' (allConsumed bodyflow) loop_t $
      mkUsage (srclocOf loopbody') "being (part of) the result of the loop body"

  let consumeMerge (Id _ (Info pt) ploc) mt
        | unique pt = consume ploc $ aliases mt
      consumeMerge (TuplePattern pats _) t | Just ts <- isTupleRecord t =
        zipWithM_ consumeMerge pats ts
      consumeMerge (PatternParens pat _) t =
        consumeMerge pat t
      consumeMerge (PatternAscription pat _ _) t =
        consumeMerge pat t
      consumeMerge _ _ =
        return ()
  consumeMerge mergepat'' =<< expType mergeexp'

  -- dim handling (3)
  let sparams_anydim = M.fromList $ zip sparams $ repeat $ SizeSubst AnyDim
      loopt_anydims = applySubst (`M.lookup` sparams_anydim) $
                      patternType mergepat''
  (merge_t', _) <-
    instantiateEmptyArrayDims loc "loopres" Nonrigid $ toStruct loopt_anydims
  unify (mkUsage (srclocOf mergeexp') "matching initial loop values to pattern")
    merge_t' . toStruct =<< expType mergeexp'

  (loopt, retext) <- instantiateDimsInReturnType loc loopt_anydims
  -- We set all of the uniqueness to be unique.  This is intentional,
  -- and matches what happens for function calls.  Those arrays that
  -- really *cannot* be consumed will alias something unconsumable,
  -- and will be caught that way.
  let bound_here = S.map identName (patternIdents mergepat'') <>
                   S.fromList sparams <> form_bound
      form_bound =
        case form' of
          For v _ -> S.singleton $ identName v
          ForIn forpat _ -> S.map identName (patternIdents forpat)
          While{} -> mempty
      loopt' = second (`S.difference` S.map AliasBound bound_here) $
               loopt `setUniqueness` Unique

  return $ DoLoop sparams mergepat'' mergeexp' form' loopbody' (Info (loopt', retext)) loc

  where
    convergePattern pat body_cons body_t body_loc = do
      let consumed_merge = S.map identName (patternIdents pat) `S.intersection`
                           body_cons

          uniquePat (Wildcard (Info t) wloc) =
            Wildcard (Info $ t `setUniqueness` Nonunique) wloc
          uniquePat (PatternParens p ploc) =
            PatternParens (uniquePat p) ploc
          uniquePat (Id name (Info t) iloc)
            | name `S.member` consumed_merge =
                let t' = t `setUniqueness` Unique `setAliases` mempty
                in Id name (Info t') iloc
            | otherwise =
                let t' = case t of Scalar Record{} -> t
                                   _               -> t `setUniqueness` Nonunique
                in Id name (Info t') iloc
          uniquePat (TuplePattern pats ploc) =
            TuplePattern (map uniquePat pats) ploc
          uniquePat (RecordPattern fs ploc) =
            RecordPattern (map (fmap uniquePat) fs) ploc
          uniquePat (PatternAscription p t ploc) =
            PatternAscription p t ploc
          uniquePat p@PatternLit{} = p
          uniquePat (PatternConstr n t ps ploc) =
            PatternConstr n t (map uniquePat ps) ploc

          -- Make the pattern unique where needed.
          pat' = uniquePat pat

      pat_t <- normaliseType $ patternType pat'
      unless (toStructural body_t `subtypeOf` toStructural pat_t) $
        unexpectedType (srclocOf body_loc) (toStruct body_t) [toStruct pat_t]

      -- Check that the new values of consumed merge parameters do not
      -- alias something bound outside the loop, AND that anything
      -- returned for a unique merge parameter does not alias anything
      -- else returned.  We also update the aliases for the pattern.
      bound_outside <- asks $ S.fromList . M.keys . scopeVtable . termScope
      let combAliases t1 t2 =
            case t1 of Scalar Record{} -> t1
                       _ -> t1 `addAliases` (<>aliases t2)

          checkMergeReturn (Id pat_v (Info pat_v_t) patloc) t
            | unique pat_v_t,
              v:_ <- S.toList $
                     S.map aliasVar (aliases t) `S.intersection` bound_outside =
                lift $ typeError loc $
                "Loop return value corresponding to merge parameter " ++
                quote (prettyName pat_v) ++ " aliases " ++ prettyName v ++ "."

            | otherwise = do
                (cons,obs) <- get
                unless (S.null $ aliases t `S.intersection` cons) $
                  lift $ typeError loc $
                  "Loop return value for merge parameter " ++
                  quote (prettyName pat_v) ++
                  " aliases other consumed merge parameter."
                when (unique pat_v_t &&
                      not (S.null (aliases t `S.intersection` (cons<>obs)))) $
                  lift $ typeError loc $
                  "Loop return value for consuming merge parameter " ++
                  quote (prettyName pat_v) ++ " aliases previously returned value."
                if unique pat_v_t
                  then put (cons<>aliases t, obs)
                  else put (cons, obs<>aliases t)

                return $ Id pat_v (Info (combAliases pat_v_t t)) patloc

          checkMergeReturn (Wildcard (Info pat_v_t) patloc) t =
            return $ Wildcard (Info (combAliases pat_v_t t)) patloc

          checkMergeReturn (PatternParens p _) t =
            checkMergeReturn p t

          checkMergeReturn (PatternAscription p _ _) t =
            checkMergeReturn p t

          checkMergeReturn (RecordPattern pfs patloc) (Scalar (Record tfs)) =
            RecordPattern . M.toList <$> sequence pfs' <*> pure patloc
            where pfs' = M.intersectionWith checkMergeReturn
                         (M.fromList pfs) tfs

          checkMergeReturn (TuplePattern pats patloc) t
            | Just ts <- isTupleRecord t =
                TuplePattern
                <$> zipWithM checkMergeReturn pats ts
                <*> pure patloc

          checkMergeReturn p _ =
            return p

      (pat'', (pat_cons, _)) <-
        runStateT (checkMergeReturn pat' body_t) (mempty, mempty)

      let body_cons' = body_cons <> S.map aliasVar pat_cons
      if body_cons' == body_cons && patternType pat'' == patternType pat
        then return pat'
        else convergePattern pat'' body_cons' body_t body_loc

checkExp (Constr name es NoInfo loc) = do
  t <- newTypeVar loc "t"
  es' <- mapM checkExp es
  ets <- mapM expType es'
  mustHaveConstr (mkUsage loc "use of constructor") name t (toStruct <$> ets)
  -- A sum value aliases *anything* that went into its construction.
  let als = mconcat (map aliases ets)
  return $ Constr name es' (Info $ fromStruct t `addAliases` (<>als)) loc

checkExp (Match e cs _ loc) =
  sequentially (checkExp e) $ \e' _ -> do
    mt <- expType e'
    (cs', t, retext) <- checkCases mt cs
    zeroOrderType (mkUsage loc "being returned 'match'") "returned from pattern match" t
    return $ Match e' cs' (Info t, Info retext) loc

checkCases :: PatternType
           -> NE.NonEmpty (CaseBase NoInfo Name)
           -> TermTypeM (NE.NonEmpty (CaseBase Info VName), PatternType, [VName])
checkCases mt rest_cs =
  case NE.uncons rest_cs of
    (c, Nothing) -> do
      (c', t) <- checkCase mt c
      return (c' NE.:| [], t, [])
    (c, Just cs) -> do
      (((c', c_t), (cs', cs_t, _)), dflow) <-
        tapOccurences $ checkCase mt c `alternative` checkCases mt cs
      (brancht, retext) <- unifyBranchTypes (srclocOf c) c_t cs_t
      let t = addAliases brancht
              (`S.difference` S.map AliasBound (allConsumed dflow))
      return (NE.cons c' cs', t, retext)

checkCase :: PatternType -> CaseBase NoInfo Name
          -> TermTypeM (CaseBase Info VName, PatternType)
checkCase mt (CasePat p caseExp loc) =
  bindingPattern p (Ascribed mt) $ \p' -> do
    caseExp' <- checkExp caseExp
    caseType <- expType caseExp'
    return (CasePat p' caseExp' loc, caseType)

-- | An unmatched pattern. Used in in the generation of
-- unmatched pattern warnings by the type checker.
data Unmatched p = UnmatchedNum p [ExpBase Info VName]
                 | UnmatchedBool p
                 | UnmatchedConstr p
                 | Unmatched p
                 deriving (Functor, Show)

instance Pretty (Unmatched (PatternBase Info VName)) where
  ppr um = case um of
      (UnmatchedNum p nums) -> ppr' p <+> text "where p is not one of" <+> ppr nums
      (UnmatchedBool p)     -> ppr' p
      (UnmatchedConstr p)     -> ppr' p
      (Unmatched p)         -> ppr' p
    where
      ppr' (PatternAscription p t _) = ppr p <> text ":" <+> ppr t
      ppr' (PatternParens p _)       = parens $ ppr' p
      ppr' (Id v _ _)                = pprName v
      ppr' (TuplePattern pats _)     = parens $ commasep $ map ppr' pats
      ppr' (RecordPattern fs _)      = braces $ commasep $ map ppField fs
        where ppField (name, t)      = text (nameToString name) <> equals <> ppr' t
      ppr' Wildcard{}                = text "_"
      ppr' (PatternLit e _ _)        = ppr e
      ppr' (PatternConstr n _ ps _)   = text "#" <> ppr n <+> sep (map ppr' ps)

unpackPat :: Pattern -> [Maybe Pattern]
unpackPat Wildcard{} = [Nothing]
unpackPat (PatternParens p _) = unpackPat p
unpackPat Id{} = [Nothing]
unpackPat (TuplePattern ps _) = Just <$> ps
unpackPat (RecordPattern fs _) = Just . snd <$> sortFields (M.fromList fs)
unpackPat (PatternAscription p _ _) = unpackPat p
unpackPat p@PatternLit{} = [Just p]
unpackPat p@PatternConstr{} = [Just p]

wildPattern :: Pattern -> Int -> Unmatched Pattern -> Unmatched Pattern
wildPattern (TuplePattern ps loc) pos um = wildTuple <$> um
  where wildTuple p = TuplePattern (take (pos - 1) ps' ++ [p] ++ drop pos ps') loc
        ps' = map wildOut ps
        wildOut p = Wildcard (Info (patternType p)) (srclocOf p)
wildPattern (RecordPattern fs loc) pos um = wildRecord <$> um
  where wildRecord p =
          RecordPattern (take (pos - 1) fs' ++ [(fst (fs!!(pos - 1)), p)] ++ drop pos fs') loc
        fs' = map wildOut fs
        wildOut (f,p) = (f, Wildcard (Info (patternType p)) (srclocOf p))
wildPattern (PatternAscription p _ _) pos um = wildPattern p pos um
wildPattern (PatternParens p _) pos um = wildPattern p pos um
wildPattern (PatternConstr n t ps loc) pos um = wildConstr <$> um
  where wildConstr p = PatternConstr n t (take (pos - 1) ps' ++ [p] ++ drop pos ps') loc
        ps' = map wildOut ps
        wildOut p = Wildcard (Info (patternType p)) (srclocOf p)
wildPattern _ _ um = um

checkUnmatched :: (MonadBreadCrumbs m, MonadTypeChecker m) => Exp -> m ()
checkUnmatched e = void $ checkUnmatched' e >> astMap tv e
  where checkUnmatched' (Match _ cs _ loc) =
          let ps = fmap (\(CasePat p _ _) -> p) cs
          in case unmatched id $ NE.toList ps of
              []  -> return ()
              ps' -> typeError loc $ "Unmatched cases in match expression: \n"
                                     ++ unlines (map (("  " ++) . pretty) ps')
        checkUnmatched' _ = return ()
        tv = ASTMapper { mapOnExp =
                           \e' -> checkUnmatched' e' >> return e'
                       , mapOnName        = pure
                       , mapOnQualName    = pure
                       , mapOnStructType  = pure
                       , mapOnPatternType = pure
                       }

-- | A data type for constructor patterns.  This is used to make the
-- code for detecting unmatched constructors cleaner, by separating
-- the constructor-pattern cases from other cases.
data ConstrPat = ConstrPat { constrName :: Name
                           , constrType :: PatternType
                           , constrPayload :: [Pattern]
                           , constrSrcLoc :: SrcLoc
                           }

-- Be aware of these fishy equality instances!

instance Eq ConstrPat where
  ConstrPat c1 _ _ _ == ConstrPat c2 _ _ _ = c1 == c2

instance Ord ConstrPat where
  ConstrPat c1 _ _ _ `compare` ConstrPat c2 _ _ _ = c1 `compare` c2

unmatched :: (Unmatched Pattern -> Unmatched Pattern) -> [Pattern] -> [Unmatched Pattern]
unmatched hole orig_ps
  | p:_ <- orig_ps,
    sameStructure labeledCols = do
    (i, cols) <- labeledCols
    let hole' = if isConstr p then hole else hole . wildPattern p i
    case sequence cols of
      Nothing -> []
      Just cs
        | all isPatternLit cs  -> map hole' $ localUnmatched cs
        | otherwise            -> unmatched hole' cs
  | otherwise = []

  where labeledCols = zip [1..] $ transpose $ map unpackPat orig_ps

        localUnmatched :: [Pattern] -> [Unmatched Pattern]
        localUnmatched [] = []
        localUnmatched ps'@(p':_) =
          case patternType p'  of
            Scalar (Sum cs'') ->
              -- We now know that we are matching a sum type, and thus
              -- that all patterns ps' are constructors (checked by
              -- 'all isPatternLit' before this function is called).
              let constrs   = M.keys cs''
                  matched   = mapMaybe constr ps'
                  unmatched' = map (UnmatchedConstr . buildConstr cs'') $
                               constrs \\ map constrName matched
             in case unmatched' of
                [] ->
                  let constrGroups   = group (sort matched)
                      removedConstrs = mapMaybe stripConstrs constrGroups
                      transposed     = (fmap . fmap) transpose removedConstrs
                      findUnmatched (pc, trans) = do
                        col <- trans
                        case col of
                          []           -> []
                          ((i, _):_) -> unmatched (wilder i pc) (map snd col)
                      wilder i pc s = (`PatternParens` noLoc) <$> wildPattern pc i s
                  in concatMap findUnmatched transposed
                _ -> unmatched'
            Scalar (Prim t) | not (any idOrWild ps') ->
              -- We now know that we are matching a sum type, and thus
              -- that all patterns ps' are literals (checked by 'all
              -- isPatternLit' before this function is called).
                case t of
                  Bool ->
                    let matched = nub $ mapMaybe (pExp >=> bool) $ filter isPatternLit ps'
                    in map (UnmatchedBool . buildBool (Scalar (Prim t))) $ [True, False] \\ matched
                  _ ->
                    let matched = mapMaybe pExp $ filter isPatternLit ps'
                    in [UnmatchedNum (buildId (Info $ Scalar $ Prim t) "p") matched]
            _ -> []

        isConstr PatternConstr{} = True
        isConstr (PatternParens p _) = isConstr p
        isConstr _ = False


        stripConstrs :: [ConstrPat] -> Maybe (Pattern, [[(Int, Pattern)]])
        stripConstrs (pc@ConstrPat{} : cs') = Just (unConstr pc, stripConstr pc : map stripConstr cs')
        stripConstrs [] = Nothing

        stripConstr :: ConstrPat -> [(Int, Pattern)]
        stripConstr (ConstrPat _ _  ps' _) = zip [1..] ps'

        sameStructure [] = True
        sameStructure (x:xs) = all (\y -> length y == length x' ) xs'
          where (x':xs') = map snd (x:xs)

        pExp (PatternLit e' _ _) = Just e'
        pExp _ = Nothing

        constr (PatternConstr c (Info t) ps loc) = Just $ ConstrPat c t ps loc
        constr (PatternParens p _) = constr p
        constr (PatternAscription p' _ _)  = constr p'
        constr _ = Nothing

        unConstr p =
          PatternConstr (constrName p) (Info $ constrType p) (constrPayload p) (constrSrcLoc p)

        isPatternLit PatternLit{} = True
        isPatternLit (PatternAscription p' _ _) = isPatternLit p'
        isPatternLit (PatternParens p' _)  = isPatternLit p'
        isPatternLit PatternConstr{} = True
        isPatternLit _ = False

        idOrWild Id{} = True
        idOrWild Wildcard{} = True
        idOrWild (PatternAscription p' _ _) = idOrWild p'
        idOrWild (PatternParens p' _) = idOrWild p'
        idOrWild _ = False

        bool (Literal (BoolValue b) _ ) = Just b
        bool _ = Nothing

        buildConstr m c =
          let t      = Scalar $ Sum m
              cs     = m M.! c
              wildCS = map (\ct -> Wildcard (Info ct) noLoc) cs
          in if null wildCS
               then PatternConstr c (Info t) [] noLoc
               else PatternParens (PatternConstr c (Info t) wildCS noLoc) noLoc
        buildBool t b =
          PatternLit (Literal (BoolValue b) noLoc) (Info (vacuousShapeAnnotations t)) noLoc
        buildId t n =
          -- The VName tag here will never be used since the value
          -- exists exclusively for printing warnings.
          Id (VName (nameFromString n) (-1)) t noLoc

checkIdent :: IdentBase NoInfo Name -> TermTypeM Ident
checkIdent (Ident name _ loc) = do
  (QualName _ name', vt) <- lookupVar loc (qualName name)
  return $ Ident name' (Info vt) loc

checkDimIndex :: DimIndexBase NoInfo Name -> TermTypeM DimIndex
checkDimIndex (DimFix i) =
  DimFix <$> (unifies "use as index" (Scalar $ Prim $ Signed Int32) =<< checkExp i)
checkDimIndex (DimSlice i j s) =
  DimSlice <$> check i <*> check j <*> check s
  where check = maybe (return Nothing) $
                fmap Just . unifies "use as index" (Scalar $ Prim $ Signed Int32) <=< checkExp

sequentially :: TermTypeM a -> (a -> Occurences -> TermTypeM b) -> TermTypeM b
sequentially m1 m2 = do
  (a, m1flow) <- collectOccurences m1
  (b, m2flow) <- collectOccurences $ m2 a m1flow
  occur $ m1flow `seqOccurences` m2flow
  return b

type Arg = (Exp, PatternType, Occurences, SrcLoc)

argExp :: Arg -> Exp
argExp (e, _, _, _) = e

argType :: Arg -> PatternType
argType (_, t, _, _) = t

checkArg :: UncheckedExp -> TermTypeM Arg
checkArg arg = do
  (arg', dflow) <- collectOccurences $ checkExp arg
  arg_t <- expType arg'
  return (arg', arg_t, dflow, srclocOf arg')

instantiateDimsInReturnType :: SrcLoc -> TypeBase (DimDecl VName) als
                            -> TermTypeM (TypeBase (DimDecl VName) als, [VName])
instantiateDimsInReturnType tloc = instantiateEmptyArrayDims tloc "ret" Rigid

checkApply :: SrcLoc -> PatternType -> Arg
           -> TermTypeM (PatternType, PatternType, Maybe VName, [VName])
checkApply loc (Scalar (Arrow as pname tp1 tp2)) (argexp, argtype, dflow, argloc) = do
  expect (mkUsage argloc "use as function argument") (toStruct tp1) (toStruct argtype)

  -- Perform substitutions of instantiated variables in the types.
  tp1' <- normaliseType tp1
  (tp2', ext) <- instantiateDimsInReturnType loc =<< normaliseType tp2
  argtype' <- normaliseType argtype

  occur [observation as loc]

  checkOccurences dflow
  occurs <- consumeArg argloc argtype' (diet tp1')

  case anyConsumption dflow of
    Just c ->
      let msg = "of value computed with consumption at " ++ locStr (location c)
      in zeroOrderType (mkUsage argloc "potential consumption in expression") msg tp1
    _ -> return ()

  occur $ dflow `seqOccurences` occurs
  (argext, parsubst) <-
    case pname of
      Named pname' -> do
        (d, argext) <- sizeSubst tp1' argexp
        return (argext,
                (`M.lookup` M.singleton pname' (SizeSubst d)))
      _ -> return (Nothing, const Nothing)
  let tp2'' = applySubst parsubst $ returnType tp2' (diet tp1') argtype'

  return (tp1', tp2'', argext, ext)
  where sizeSubst (Scalar (Prim (Signed Int32))) e = dimFromArg e
        sizeSubst _ _ = return (AnyDim, Nothing)

checkApply loc tfun@(Scalar TypeVar{}) arg = do
  tv <- newTypeVar loc "b"
  unify (mkUsage loc "use as function") (toStruct tfun) $
    Scalar $ Arrow mempty Unnamed (toStruct (argType arg)) tv
  constraints <- getConstraints
  checkApply loc (applySubst (`lookupSubst` constraints) tfun) arg

checkApply loc ftype arg =
  typeError loc $
  "Attempt to apply an expression of type " ++ pretty ftype ++
  " to an argument of type " ++ pretty (argType arg) ++ "."

isInt32 :: Exp -> Maybe Int32
isInt32 (Literal (SignedValue (Int32Value k')) _) = Just $ fromIntegral k'
isInt32 (IntLit k' _ _) = Just $ fromInteger k'
isInt32 (Negate x _) = negate <$> isInt32 x
isInt32 _ = Nothing

maybeDimFromArg :: Exp -> Maybe (DimDecl VName)
maybeDimFromArg (Var v _ _) = Just $ NamedDim v
maybeDimFromArg (Parens e _) = maybeDimFromArg e
maybeDimFromArg (QualParens _ e _) = maybeDimFromArg e
maybeDimFromArg e = ConstDim . fromIntegral <$> isInt32 e

dimFromArg :: Exp -> TermTypeM (DimDecl VName, Maybe VName)
dimFromArg (Parens e _) = dimFromArg e
dimFromArg (QualParens _ e _) = dimFromArg e
dimFromArg e
  | Just d <- maybeDimFromArg e =
      return (d, Nothing)
  | otherwise =
      extSize (srclocOf e) $ SourceExp $ bareExp e

-- | @returnType ret_type arg_diet arg_type@ gives result of applying
-- an argument the given types to a function with the given return
-- type, consuming the argument with the given diet.
returnType :: PatternType
           -> Diet
           -> PatternType
           -> PatternType
returnType (Array _ Unique et shape) _ _ =
  Array mempty Unique et shape
returnType (Array als Nonunique et shape) d arg =
  Array (als<>arg_als) Unique et shape -- Intentional!
  where arg_als = aliases $ maskAliases arg d
returnType (Scalar (Record fs)) d arg =
  Scalar $ Record $ fmap (\et -> returnType et d arg) fs
returnType (Scalar (Prim t)) _ _ =
  Scalar $ Prim t
returnType (Scalar (TypeVar _ Unique t targs)) _ _ =
  Scalar $ TypeVar mempty Unique t targs
returnType (Scalar (TypeVar als Nonunique t targs)) d arg =
  Scalar $ TypeVar (als<>arg_als) Unique t targs -- Intentional!
  where arg_als = aliases $ maskAliases arg d
returnType (Scalar (Arrow _ v t1 t2)) d arg =
  Scalar $ Arrow als v (t1 `setAliases` mempty) (t2 `setAliases` als)
  where als = aliases $ maskAliases arg d
returnType (Scalar (Sum cs)) d arg =
  Scalar $ Sum $ (fmap . fmap) (\et -> returnType et d arg) cs

-- | @t `maskAliases` d@ removes aliases (sets them to 'mempty') from
-- the parts of @t@ that are denoted as consumed by the 'Diet' @d@.
maskAliases :: Monoid as =>
               TypeBase shape as
            -> Diet
            -> TypeBase shape as
maskAliases t Consume = t `setAliases` mempty
maskAliases t Observe = t
maskAliases (Scalar (Record ets)) (RecordDiet ds) =
  Scalar $ Record $ M.intersectionWith maskAliases ets ds
maskAliases t FuncDiet{} = t
maskAliases _ _ = error "Invalid arguments passed to maskAliases."

consumeArg :: SrcLoc -> PatternType -> Diet -> TermTypeM [Occurence]
consumeArg loc (Scalar (Record ets)) (RecordDiet ds) =
  concat . M.elems <$> traverse (uncurry $ consumeArg loc) (M.intersectionWith (,) ets ds)
consumeArg loc (Array _ Nonunique _ _) Consume =
  typeError loc "Consuming parameter passed non-unique argument."
consumeArg loc (Scalar (Arrow _ _ t1 _)) (FuncDiet d _)
  | not $ contravariantArg t1 d =
      typeError loc "Non-consuming higher-order parameter passed consuming argument."
  where contravariantArg (Array _ Unique _ _) Observe =
          False
        contravariantArg (Scalar (TypeVar _ Unique _ _)) Observe =
          False
        contravariantArg (Scalar (Record ets)) (RecordDiet ds) =
          and (M.intersectionWith contravariantArg ets ds)
        contravariantArg (Scalar (Arrow _ _ tp tr)) (FuncDiet dp dr) =
          contravariantArg tp dp && contravariantArg tr dr
        contravariantArg _ _ =
          True
consumeArg loc (Scalar (Arrow _ _ _ t2)) (FuncDiet _ pd) =
  consumeArg loc t2 pd
consumeArg loc at Consume = return [consumption (aliases at) loc]
consumeArg loc at _       = return [observation (aliases at) loc]

checkOneExp :: UncheckedExp -> TypeM ([TypeParam], Exp)
checkOneExp e = fmap fst . runTermTypeM $ do
  e' <- checkExp e
  let t = toStruct $ typeOf e'
  (tparams, _, _, _) <-
    letGeneralise (nameFromString "<exp>") (srclocOf e) [] [] t
  fixOverloadedTypes
  e'' <- updateTypes e'
  return (tparams, e'')

constructivelyBound :: [Pattern] -> S.Set VName
constructivelyBound = foldMap (onType . patternStructType)
  where onType (Scalar Arrow{}) = mempty
        onType (Scalar Prim{}) = mempty
        onType (Scalar (Record fields)) = foldMap onType fields
        onType (Scalar (Sum cs)) = foldMap (foldMap onType) cs
        onType (Scalar (TypeVar _ _ tn _)) = S.singleton $ typeLeaf tn
        onType (Array _ _ t _) = onType $ Scalar t

-- Verify that all sum type constructors and empty array literals have
-- a size that is known (rigid or a type parameter).  This is to
-- ensure that we can actually determine their shape at run-time.
verifyConstructive :: [TypeParam] -> [Pattern] -> Exp -> TermTypeM ()
verifyConstructive tparams params body = do
  constraints <- getConstraints
  either throwError (const $ return ()) $ onExp constraints body
  where tparams_names = map typeParamName tparams
        constructively_bound = constructivelyBound params

        nonconstructiveParam v =
          (v `elem` tparams_names) &&
          (v `notElem` constructively_bound)

        onExp constraints (Constr _ _ (Info t) loc)
          | ds <- nonconstructive constraints t,
            not $ null ds =
              ambig loc ds t
        onExp constraints (ArrayLit [] (Info t) loc)
          | ds <- nonconstructive constraints t,
            not $ null ds =
              ambig loc ds t
        onExp constraints e = astMap mapper e
          where mapper = identityMapper { mapOnExp = onExp constraints }

        nonconstructive constraints t
          | names_in_t <- typeVars t,
            vs <- filter nonconstructiveParam $ S.toList names_in_t,
            not $ null vs =
              vs
          | otherwise =
              mapMaybe (nonconstructiveDim constraints) $
              S.toList $ typeDimNames t

        nonconstructiveDim constraints v
          | Just (_, Size Nothing _) <- v `M.lookup` constraints =
              Just v
        nonconstructiveDim _ _ =
          Nothing

        ambig loc ds t =
          Left $
          TypeError loc $ unlines [ "Inferred expression to have type:"
                                  , sindent $ pretty t
                                  , "Where the following sizes are ambiguous:"
                                  , "  " ++ intercalate ", " (map prettyName ds)
                                  , "Add type annotations to disambiguate."
                                  ]

        sindent = intercalate "\n" . map ("  "++) . lines

-- | Type-check a top-level (or module-level) function definition.
-- Despite the name, this is also used for checking constant
-- definitions, by treating them as 0-ary functions.
checkFunDef :: (Name, Maybe UncheckedTypeExp,
                [UncheckedTypeParam], [UncheckedPattern],
                UncheckedExp, SrcLoc)
            -> TypeM (VName, [TypeParam], [Pattern], Maybe (TypeExp VName),
                      StructType, [VName], Exp)
checkFunDef (fname, maybe_retdecl, tparams, params, body, loc) =
  fmap fst $ runTermTypeM $ do
  (tparams', params', maybe_retdecl', rettype', retext, body') <-
    checkBinding (Just fname, maybe_retdecl, tparams, params, body, loc)

  -- Since this is a top-level function, we also resolve overloaded
  -- types, using either defaults or complaining about ambiguities.
  fixOverloadedTypes

  -- Then replace all inferred types in the body and parameters.
  body'' <- updateTypes body'
  params'' <- updateTypes params'
  maybe_retdecl'' <- traverse updateTypes maybe_retdecl'
  rettype'' <- normaliseType rettype'

  -- Check if pattern matches are exhaustive and yield
  -- errors if not.
  checkUnmatched body''

  -- Check if the function body can actually be evaluated.
  verifyConstructive tparams' params'' body''

  bindSpaced [(Term, fname)] $ do
    fname' <- checkName Term fname loc
    when (nameToString fname `elem` doNotShadow) $
      typeError loc $ "The " ++ nameToString fname ++ " operator may not be redefined."

    return (fname', tparams', params'', maybe_retdecl'', rettype'', retext, body'')

-- | This is "fixing" as in "setting them", not "correcting them".  We
-- only make very conservative fixing.
fixOverloadedTypes :: TermTypeM ()
fixOverloadedTypes = getConstraints >>= mapM_ fixOverloaded . M.toList . M.map snd
  where fixOverloaded (v, Overloaded ots usage)
          | Signed Int32 `elem` ots = do
              unify usage (Scalar (TypeVar () Nonunique (typeName v) [])) $
                Scalar $ Prim $ Signed Int32
              warn usage "Defaulting ambiguous type to `i32`."
          | FloatType Float64 `elem` ots = do
              unify usage (Scalar (TypeVar () Nonunique (typeName v) [])) $
                Scalar $ Prim $ FloatType Float64
              warn usage "Defaulting ambiguous type to `f64`."
          | otherwise =
              typeError usage $
              unlines ["Type is ambiguous (could be one of " ++ intercalate ", " (map pretty ots) ++ ").",
                       "Add a type annotation to disambiguate the type."]

        fixOverloaded (_, NoConstraint _ usage) =
          typeError usage $ unlines ["Type of expression is ambiguous.",
                                     "Add a type annotation to disambiguate the type."]

        fixOverloaded (_, Equality usage) =
          typeError usage $ unlines ["Type is ambiguous (must be equality type).",
                                     "Add a type annotation to disambiguate the type."]

        fixOverloaded (_, HasFields fs usage) =
          typeError usage $ unlines ["Type is ambiguous.  Must be record with fields:",
                                     unlines $ map field $ M.toList fs,
                                     "Add a type annotation to disambiguate the type."]
          where field (l, t) = pretty $ indent 2 $ ppr l <> colon <+> align (ppr t)

        fixOverloaded (_, HasConstrs cs usage) =
          typeError usage $ unlines [ "Type is ambiguous (must be a sum type with constructors: " ++
                                      pretty (Sum cs) ++ ")."
                                    , "Add a type annotation to disambiguate the type."]

        fixOverloaded _ = return ()

hiddenParamNames :: [Pattern] -> Names
hiddenParamNames params = hidden
  where param_all_names = S.map identName $ mconcat $ map patternIdents params
        named (Named x, _) = Just x
        named (Unnamed, _) = Nothing
        param_names =
          S.fromList $ mapMaybe (named . patternParam) params
        hidden = param_all_names `S.difference` param_names

inferredReturnType :: SrcLoc -> [Pattern] -> PatternType -> TermTypeM StructType
inferredReturnType loc params t =
  -- The inferred type may refer to names that are bound by
  -- the parameter patterns, but which will not be visible
  -- in the type.  These we must turn into fresh type
  -- variables, which will be existential in the return
  -- type.
  fmap fst $
  instantiateEmptyArrayDims loc "inferret" Rigid $
  toStruct $ unscopeType (hiddenParamNames params) $ fromStruct $
  inferReturnUniqueness params t

checkBinding :: (Maybe Name, Maybe UncheckedTypeExp,
                 [UncheckedTypeParam], [UncheckedPattern],
                 UncheckedExp, SrcLoc)
             -> TermTypeM ([TypeParam], [Pattern], Maybe (TypeExp VName),
                           StructType, [VName], Exp)
checkBinding (fname, maybe_retdecl, tparams, params, body, loc) =
  noUnique $ incLevel $ bindingParams tparams params $ \tparams' params' -> do
    maybe_retdecl' <- forM maybe_retdecl $ \retdecl -> do
      (retdecl', ret_nodims, _) <- checkTypeExp retdecl
      (ret, _) <- instantiateEmptyArrayDims loc "funret" Nonrigid ret_nodims
      return (retdecl', ret)

    body' <- checkFunBody params' body
             (snd <$> maybe_retdecl')
             (maybe loc srclocOf maybe_retdecl)

    params'' <- mapM updateTypes params'
    body_t <- expType body'

    (maybe_retdecl'', rettype) <- case maybe_retdecl' of
      Just (retdecl', ret) -> do
        let rettype_structural = toStructural ret
        checkReturnAlias rettype_structural params'' body_t

        when (null params) $ nothingMustBeUnique loc rettype_structural

        ret' <- normaliseType ret

        return (Just retdecl', ret')

      Nothing
        | null params ->
            return (Nothing, toStruct $ body_t `setUniqueness` Nonunique)
        | otherwise -> do
            body_t' <- inferredReturnType loc params'' body_t
            return (Nothing, body_t')

    verifyFunctionParams params''

    (tparams'', params''', rettype'', retext) <-
      letGeneralise (fromMaybe (nameFromString "lambda") fname)
      loc tparams' params'' rettype

    checkGlobalAliases params'' body_t loc

    let msg = unlines [ show fname
                      , pretty body_t
                      , pretty rettype''
                      , "retext: " ++ unwords (map prettyName retext)
                      ]
    return (tparams'', params''', maybe_retdecl'', rettype'', retext, body')

  where -- | Check that unique return values do not alias a
        -- non-consumed parameter.
        checkReturnAlias rettp params' =
          foldM_ (checkReturnAlias' params') S.empty . returnAliasing rettp
        checkReturnAlias' params' seen (Unique, names)
          | any (`S.member` S.map snd seen) $ S.toList names =
              uniqueReturnAliased fname loc
          | otherwise = do
              notAliasingParam params' names
              return $ seen `S.union` tag Unique names
        checkReturnAlias' _ seen (Nonunique, names)
          | any (`S.member` seen) $ S.toList $ tag Unique names =
            uniqueReturnAliased fname loc
          | otherwise = return $ seen `S.union` tag Nonunique names

        notAliasingParam params' names =
          forM_ params' $ \p ->
          let consumedNonunique p' =
                not (unique $ unInfo $ identType p') && (identName p' `S.member` names)
          in case find consumedNonunique $ S.toList $ patternIdents p of
               Just p' ->
                 returnAliased fname (baseName $ identName p') loc
               Nothing ->
                 return ()

        tag u = S.map (u,)

        returnAliasing (Scalar (Record ets1)) (Scalar (Record ets2)) =
          concat $ M.elems $ M.intersectionWith returnAliasing ets1 ets2
        returnAliasing expected got =
          [(uniqueness expected, S.map aliasVar $ aliases got)]

-- | Extract all the shape names that occur in positive position
-- (roughly, left side of an arrow) in a given type.
typeDimNamesPos :: TypeBase (DimDecl VName) als -> S.Set VName
typeDimNamesPos (Scalar (Arrow _ _ t1 t2)) = onParam t1 <> typeDimNamesPos t2
  where onParam :: TypeBase (DimDecl VName) als -> S.Set VName
        onParam (Scalar Arrow{}) = mempty
        onParam (Scalar (Record fs)) = mconcat $ map onParam $ M.elems fs
        onParam (Scalar (TypeVar _ _ _ targs)) = mconcat $ map onTypeArg targs
        onParam t = typeDimNames t
        onTypeArg (TypeArgDim (NamedDim d) _) = S.singleton $ qualLeaf d
        onTypeArg (TypeArgDim _ _) = mempty
        onTypeArg (TypeArgType t _) = onParam t
typeDimNamesPos _ = mempty

checkGlobalAliases :: [Pattern] -> PatternType -> SrcLoc -> TermTypeM ()
checkGlobalAliases params body_t loc = do
  vtable <- asks $ scopeVtable . termScope
  let isLocal v = case v `M.lookup` vtable of
                    Just (BoundV Local _ _) -> True
                    _ -> False
  let als = filter (not . isLocal) $ S.toList $
            boundArrayAliases body_t `S.difference`
            S.map identName (mconcat (map patternIdents params))
  case als of
    v:_ | not $ null params ->
      typeError loc $
      unlines [ "Function result aliases the free variable " <>
                quote (prettyName v) <> "."
              , "Use " ++ quote "copy" ++ " to break the aliasing."]
    _ ->
      return ()

inferReturnUniqueness :: [Pattern] -> PatternType -> StructType
inferReturnUniqueness params t =
  let forbidden = aliasesMultipleTimes t
      uniques = uniqueParamNames params
      delve (Scalar (Record fs)) =
        Scalar $ Record $ M.map delve fs
      delve t'
        | all (`S.member` uniques) (boundArrayAliases t'),
          not $ any ((`S.member` forbidden) . aliasVar) (aliases t') =
            toStruct t'
        | otherwise =
            toStruct $ t' `setUniqueness` Nonunique
  in delve t

-- An alias inhibits uniqueness if it is used in disjoint values.
aliasesMultipleTimes :: PatternType -> Names
aliasesMultipleTimes = S.fromList . map fst . filter ((>1) . snd) . M.toList . delve
  where delve (Scalar (Record fs)) =
          foldl' (M.unionWith (+)) mempty $ map delve $ M.elems fs
        delve t =
          M.fromList $ zip (map aliasVar $ S.toList (aliases t)) $ repeat (1::Int)

uniqueParamNames :: [Pattern] -> Names
uniqueParamNames =
  S.fromList . map identName
  . filter (unique . unInfo . identType)
  . S.toList . mconcat . map patternIdents

boundArrayAliases :: PatternType -> S.Set VName
boundArrayAliases (Array als _ _ _) = boundAliases als
boundArrayAliases (Scalar Prim{}) = mempty
boundArrayAliases (Scalar (Record fs)) = foldMap boundArrayAliases fs
boundArrayAliases (Scalar (TypeVar als _ _ _)) = boundAliases als
boundArrayAliases (Scalar Arrow{}) = mempty
boundArrayAliases (Scalar (Sum fs)) =
  mconcat $ concatMap (map boundArrayAliases) $ M.elems fs

-- | The set of in-scope variables that are being aliased.
boundAliases :: Aliasing -> S.Set VName
boundAliases = S.map aliasVar . S.filter bound
  where bound AliasBound{} = True
        bound AliasFree{} = False

nothingMustBeUnique :: SrcLoc -> TypeBase () () -> TermTypeM ()
nothingMustBeUnique loc = check
  where check (Array _ Unique _ _) = bad
        check (Scalar (TypeVar _ Unique _ _)) = bad
        check (Scalar (Record fs)) = mapM_ check fs
        check _ = return ()
        bad = typeError loc "A top-level constant cannot have a unique type."

-- | Verify certain restrictions on function parameters, and bail out
-- on dubious constructions.
--
-- These restrictions apply to all functions (anonymous or otherwise).
-- Top-level functions have further restrictions that are checked
-- during let-generalisation.
verifyFunctionParams :: [Pattern] -> TermTypeM ()
verifyFunctionParams params =
  verifyParams (mconcat (map patternNames params)) =<< mapM updateTypes params
  where
    verifyParams forbidden (p:ps)
      | d:_ <- S.toList $ patternDimNames p `S.intersection` forbidden =
          typeError p $ unlines [ "Parameter " ++ quote (pretty p) ++
                                  " refers to size " ++ quote (prettyName d) ++ ","
                                , "which will not be accessible to the caller, possibly because it is nested in a tuple or record."
                                , ""
                                , "Consider ascribing an explicit type that does not reference "
                                  ++ quote (prettyName d) ++ "."]
      | otherwise = verifyParams forbidden' ps
      where forbidden' =
              case patternParam p of
                (Named v, _) -> forbidden `S.difference` S.singleton v
                _            -> forbidden

    verifyParams _ [] = return ()

-- Returns a pair of the sizes of the immediate type produced, as well
-- as the sizes of parameter types.
dimUses :: StructType -> (Names, Names, Names)
dimUses = execWriter . traverseDims f
  where f PosImmediate (NamedDim v) = tell (S.singleton (qualLeaf v), mempty, mempty)
        f PosParam (NamedDim v) = tell (mempty, S.singleton (qualLeaf v), mempty)
        f PosReturn (NamedDim v) = tell (mempty, mempty, S.singleton (qualLeaf v))
        f _ _ = return ()

-- | Find at all type variables in the given type that are covered by
-- the constraints, and produce type parameters that close over them.
--
-- The passed-in list of type parameters is always prepended to the
-- produced list of type parameters.
closeOverTypes :: Name -> SrcLoc
               -> [TypeParam] -> [StructType] -> StructType
               -> Constraints -> TermTypeM ([TypeParam], StructType, [VName])
closeOverTypes defname defloc tparams paramts ret substs = do
  (more_tparams, retext) <- partitionEithers . catMaybes <$>
                            mapM closeOver (M.toList $ M.map snd to_close_over)
  let msg = unlines [prettyName defname,
                     pretty t,
--                     "substs: " ++ unwords (map prettyName (M.keys substs)),
--                     "visible: " ++ unwords (map prettyName (S.toList visible)),
                     "to close over: " ++ show to_close_over,
                     "produced: " ++ unwords (map prettyName (S.toList produced_sizes)),
                     "params: " ++ unwords (map prettyName (S.toList param_sizes)),
                     "retext: " ++ unwords (map prettyName retext)]
      retToAnyDim v = do guard $ v `S.member` ret_sizes
                         UnknowableSize{} <- snd <$> M.lookup v substs
                         Just $ SizeSubst AnyDim
  return (tparams ++ more_tparams,
          applySubst retToAnyDim ret,
          retext)
  where t = foldFunType paramts ret
        to_close_over = M.filterWithKey (\k _ -> k `S.member` visible) substs
        visible = typeVars t <> typeDimNames t

        (produced_sizes, param_sizes, ret_sizes) = dimUses t

        -- Avoid duplicate type parameters.
        closeOver (k, _)
          | k `elem` map typeParamName tparams =
              return Nothing
        closeOver (k, NoConstraint l usage) =
          return $ Just $ Left $ TypeParamType l k $ srclocOf usage
        closeOver (k, Size Nothing usage) =
          return $ Just $ Left $ TypeParamDim k $ srclocOf usage
        closeOver (k, ParamType l loc) =
          return $ Just $ Left $ TypeParamType l k loc
        closeOver (k, UnknowableSize sloc)
          | k `S.member` param_sizes =
              typeError defloc $
              unlines [ "Unknowable size " ++ quote (prettyName k) ++
                        " produced at " ++ locStr sloc
                      , "imposes constraint on type of " ++ quote (prettyName defname) ++
                        ", which is inferred as:"
                      , unlines $ map (++"  ") $ lines $ pretty t ]
          | k `S.member` produced_sizes =
              return $ Just $ Right k
        closeOver (_, _) =
          return Nothing

letGeneralise :: Name -> SrcLoc
              -> [TypeParam] -> [Pattern] -> StructType
              -> TermTypeM ([TypeParam], [Pattern], StructType, [VName])
letGeneralise defname defloc tparams params rettype = do
  now_substs <- getConstraints

  -- Candidates for let-generalisation are those type variables that
  --
  -- (1) were not known before we checked this function, and
  --
  -- (2) are not used in the (new) definition of any type variables
  -- known before we checked this function.
  --
  -- (3) are not referenced from an overloaded type (for example,
  -- are the element types of an incompletely resolved record type).
  -- This is a bit more restrictive than I'd like, and SML for
  -- example does not have this restriction.
  --
  -- Criteria (1) and (2) is implemented by looking at the binding
  -- level of the type variables.
  let keep_type_vars = overloadedTypeVars now_substs

  cur_lvl <- curLevel
  let candidate k (lvl, _) = (k `S.notMember` keep_type_vars) && lvl >= cur_lvl
      new_substs = M.filterWithKey candidate now_substs

  (tparams', rettype', retext) <-
    closeOverTypes defname defloc tparams
    (map patternStructType params) rettype new_substs

  rettype'' <- updateTypes rettype'

  -- We keep those type variables that were not closed over by
  -- let-generalisation.
  modifyConstraints $ M.filterWithKey $ \k _ -> k `notElem` map typeParamName tparams'

  return (tparams', params, rettype'', retext)

checkFunBody :: [Pattern]
             -> UncheckedExp
             -> Maybe StructType
             -> SrcLoc
             -> TermTypeM Exp
checkFunBody params body maybe_rettype loc = do
  body' <- checkExp body

  -- Unify body return type with return annotation, if one exists.
  case maybe_rettype of
    Just rettype -> do
      (rettype_withdims, _) <- instantiateEmptyArrayDims loc "impl" Nonrigid rettype

      body_t <- expType body'
      -- We need to turn any sizes provided by "hidden" parameter
      -- names into existential sizes instead.
      (body_t', _) <- instantiateEmptyArrayDims loc "hidden" Rigid $
                      unscopeType (hiddenParamNames params) body_t

      let usage = mkUsage (srclocOf body) "return type annotation"
      expect usage rettype_withdims $ toStruct body_t'

      -- We also have to make sure that uniqueness matches.  This is done
      -- explicitly, because uniqueness is ignored by unification.
      rettype' <- normaliseType rettype
      body_t'' <- normaliseType rettype -- Substs may have changed.
      unless (body_t'' `subtypeOf` rettype') $
        typeError (srclocOf body) $ "Body type " ++ quote (pretty body_t'') ++
        " is not a subtype of annotated type " ++
        quote (pretty rettype') ++ "."

    Nothing -> return ()

  return body'

--- Consumption

occur :: Occurences -> TermTypeM ()
occur = tell

-- | Proclaim that we have made read-only use of the given variable.
observe :: Ident -> TermTypeM ()
observe (Ident nm (Info t) loc) =
  let als = AliasBound nm `S.insert` aliases t
  in occur [observation als loc]

-- | Proclaim that we have written to the given variable.
consume :: SrcLoc -> Aliasing -> TermTypeM ()
consume loc als = do
  vtable <- asks $ scopeVtable . termScope
  let consumable v = case M.lookup v vtable of
                       Just (BoundV Local _ t)
                         | arrayRank t > 0 -> unique t
                         | otherwise -> True
                       _ -> False
  case filter (not . consumable) $ map aliasVar $ S.toList als of
    v:_ -> typeError loc $ "Attempt to consume variable " ++ quote (prettyName v)
           ++ ", which is not allowed."
    [] -> occur [consumption als loc]

-- | Proclaim that we have written to the given variable, and mark
-- accesses to it and all of its aliases as invalid inside the given
-- computation.
consuming :: Ident -> TermTypeM a -> TermTypeM a
consuming (Ident name (Info t) loc) m = do
  consume loc $ AliasBound name `S.insert` aliases t
  localScope consume' m
  where consume' scope =
          scope { scopeVtable = M.insert name (WasConsumed loc) $ scopeVtable scope }

collectOccurences :: TermTypeM a -> TermTypeM (a, Occurences)
collectOccurences m = pass $ do
  (x, dataflow) <- listen m
  return ((x, dataflow), const mempty)

tapOccurences :: TermTypeM a -> TermTypeM (a, Occurences)
tapOccurences = listen

removeSeminullOccurences :: TermTypeM a -> TermTypeM a
removeSeminullOccurences = censor $ filter $ not . seminullOccurence

checkIfUsed :: Occurences -> Ident -> TermTypeM ()
checkIfUsed occs v
  | not $ identName v `S.member` allOccuring occs,
    not $ "_" `isPrefixOf` prettyName (identName v) =
      warn (srclocOf v) $ "Unused variable " ++ quote (pretty $ baseName $ identName v) ++ "."
  | otherwise =
      return ()

alternative :: TermTypeM a -> TermTypeM b -> TermTypeM (a,b)
alternative m1 m2 = pass $ do
  (x, occurs1) <- listen m1
  (y, occurs2) <- listen m2
  checkOccurences occurs1
  checkOccurences occurs2
  let usage = occurs1 `altOccurences` occurs2
  return ((x, y), const usage)

-- | Make all bindings nonunique.
noUnique :: TermTypeM a -> TermTypeM a
noUnique = localScope (\scope -> scope { scopeVtable = M.map set $ scopeVtable scope})
  where set (BoundV l tparams t)    = BoundV l tparams $ t `setUniqueness` Nonunique
        set (OverloadedF ts pts rt) = OverloadedF ts pts rt
        set EqualityF               = EqualityF
        set (WasConsumed loc)       = WasConsumed loc

onlySelfAliasing :: TermTypeM a -> TermTypeM a
onlySelfAliasing = localScope (\scope -> scope { scopeVtable = M.mapWithKey set $ scopeVtable scope})
  where set k (BoundV l tparams t)    = BoundV l tparams $
                                        t `addAliases` S.intersection (S.singleton (AliasBound k))
        set _ (OverloadedF ts pts rt) = OverloadedF ts pts rt
        set _ EqualityF               = EqualityF
        set _ (WasConsumed loc)       = WasConsumed loc

arrayOfM :: (Pretty (ShapeDecl dim), Monoid as) =>
            SrcLoc
         -> TypeBase dim as -> ShapeDecl dim -> Uniqueness
         -> TermTypeM (TypeBase dim as)
arrayOfM loc t shape u = do
  zeroOrderType (mkUsage loc "use as array element") "used in array" t
  return $ arrayOf t shape u

patternNames :: Pattern -> S.Set VName
patternNames = S.map identName . patternIdents

updateTypes :: ASTMappable e => e -> TermTypeM e
updateTypes = astMap tv
  where tv = ASTMapper { mapOnExp         = astMap tv
                       , mapOnName        = pure
                       , mapOnQualName    = pure
                       , mapOnStructType  = normaliseType
                       , mapOnPatternType = normaliseType
                       }
