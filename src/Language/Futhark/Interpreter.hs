{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
module Language.Futhark.Interpreter
  ( Ctx(..)
  , Env
  , InterpreterError
  , initialCtx
  , interpretExp
  , interpretDec
  , interpretImport
  , interpretFunction
  , ExtOp(..)
  , Value (ValuePrim, ValueArray, ValueRecord)
  , fromTuple
  , isEmptyArray
  , prettyEmptyArray
  ) where
import qualified Debug.Trace
import Control.Monad.Trans.Maybe
import Control.Monad.Free.Church
import Control.Monad.Except
import Control.Monad.Reader
import qualified Control.Monad.Fail as Fail
import Data.Array
import Data.Bifunctor (first)
import Data.Bitraversable
import Data.Foldable (fold)
import Data.List hiding (break)
import Data.Maybe
import qualified Data.Map as M
import qualified Data.List.NonEmpty as NE
import Data.Monoid hiding (Sum)
import Data.Loc

import Language.Futhark hiding (Value)
import qualified Language.Futhark as F
import Futhark.Representation.Primitive (intValue, floatValue)
import qualified Futhark.Representation.Primitive as P
import qualified Language.Futhark.Semantic as T

import Futhark.Util.Pretty hiding (apply, bool, stack)
import Futhark.Util (chunk, splitFromEnd, maybeHead)

import Prelude hiding (mod, break)

data ExtOp a = ExtOpTrace SrcLoc String a
             | ExtOpBreak [SrcLoc] Ctx T.Env a
             | ExtOpError InterpreterError

instance Functor ExtOp where
  fmap f (ExtOpTrace w s x) = ExtOpTrace w s $ f x
  fmap f (ExtOpBreak w ctx env x) = ExtOpBreak w ctx env $ f x
  fmap _ (ExtOpError err) = ExtOpError err

data StackFrame = StackFrame { stackFrameSrcLoc :: SrcLoc
                             , stackFrameEnv :: Env
                             }

type Stack = [StackFrame]

-- | The monad in which evaluation takes place.
newtype EvalM a = EvalM (ReaderT (Stack, M.Map FilePath Env)
                         (F ExtOp) a)
  deriving (Monad, Applicative, Functor,
            MonadFree ExtOp,
            MonadReader (Stack, M.Map FilePath Env))

instance Fail.MonadFail EvalM where
  fail = error

runEvalM :: M.Map FilePath Env -> EvalM a -> F ExtOp a
runEvalM imports (EvalM m) = runReaderT m (mempty, imports)

stacking :: SrcLoc -> Env -> EvalM a -> EvalM a
stacking loc env = local $ \(ss, imports) ->
  if isNoLoc loc then (ss, imports) else (StackFrame loc env:ss, imports)
  where isNoLoc :: SrcLoc -> Bool
        isNoLoc = (==NoLoc) . locOf

stacktrace :: EvalM [SrcLoc]
stacktrace = asks $ map stackFrameSrcLoc . reverse . fst

lookupImport :: FilePath -> EvalM (Maybe Env)
lookupImport f = asks $ M.lookup f . snd

prettyRecord :: Pretty a => M.Map Name a -> Doc
prettyRecord m
  | Just vs <- areTupleFields m =
      parens $ commasep $ map ppr vs
  | otherwise =
      braces $ commasep $ map field $ M.toList m
      where field (k, v) = ppr k <+> equals <+> ppr v

-- | A shape is a tree to accomodate the case of records.  It is
-- parameterised over the representation of dimensions.
data Shape d = ShapeDim d (Shape d)
             | ShapeLeaf
             | ShapeRecord (M.Map Name (Shape d))
             | ShapeSum (M.Map Name [Shape d])
             deriving (Eq, Show, Functor, Foldable, Traversable)

type ValueShape = Shape Int32

instance Pretty d => Pretty (Shape d) where
  ppr ShapeLeaf = mempty
  ppr (ShapeDim d s) = brackets (ppr d) <> ppr s
  ppr (ShapeRecord m) = prettyRecord m
  ppr (ShapeSum cs) =
    mconcat (punctuate (text " | ") cs')
    where ppConstr (name, fs) = sep $ (text "#" <> ppr name) : map ppr fs
          cs' = map ppConstr $ M.toList cs

emptyShape :: ValueShape -> Bool
emptyShape (ShapeDim d s) = d == 0 || emptyShape s
emptyShape _ = False

rowShape :: Shape d -> Shape d
rowShape (ShapeDim _ shape) = shape
rowShape shape = shape

projectShape :: [Name] -> Shape d -> Shape d
projectShape (k:ks) (ShapeRecord fields)
  | Just shape <- M.lookup k fields =
      projectShape ks shape
projectShape _ shape = shape

stripShapeDims :: Int -> Shape d -> Shape d
stripShapeDims 0 shape = shape
stripShapeDims i shape = stripShapeDims (i-1) $ rowShape shape

typeShape :: M.Map VName (Shape d) -> TypeBase d () -> Shape d
typeShape shapes = go
  where go (Array _ _ et shape) =
          foldr ShapeDim (go (Scalar et)) $ shapeDims shape
        go (Scalar (Record fs)) =
          ShapeRecord $ M.map go fs
        go (Scalar (Sum cs)) =
          ShapeSum $ M.map (map go) cs
        go (Scalar (TypeVar _ _ (TypeName [] v) []))
          | Just shape <- M.lookup v shapes =
              shape
        go _ =
          ShapeLeaf

structTypeShape :: M.Map VName ValueShape -> StructType -> Shape (Maybe Int32)
structTypeShape shapes = fmap dim . typeShape shapes'
  where dim (ConstDim d) = Just $ fromIntegral d
        dim _ = Nothing
        shapes' = M.map (fmap $ ConstDim . fromIntegral) shapes

-- | A fully evaluated Futhark value.
data Value = ValuePrim !PrimValue
           | ValueArray ValueShape !(Array Int Value)
             -- Stores the full shape.
           | ValueRecord (M.Map Name Value)
           | ValueFun (Maybe (ValueShape -> ValueShape)) (Value -> EvalM Value)
           | ValueSum ValueShape Name [Value]
             -- Stores the full shape.

instance Eq Value where
  ValuePrim x == ValuePrim y = x == y
  ValueArray _ x == ValueArray _ y = x == y
  ValueRecord x == ValueRecord y = x == y
  ValueSum _ n1 vs1 == ValueSum _ n2 vs2 = n1 == n2 && vs1 == vs2
  _ == _ = False

instance Pretty Value where
  ppr (ValuePrim v)  = ppr v
  ppr (ValueArray _ a) =
    let elements  = elems a -- [Value]
        (x:_)     = elements
        separator = case x of
                      ValueArray _ _ -> comma <> line
                      _              -> comma <> space
     in brackets $ cat $ punctuate separator (map ppr elements)

  ppr (ValueRecord m) = prettyRecord m
  ppr ValueFun{} = text "#<fun>"
  ppr (ValueSum _ n vs) = text "#" <> sep (ppr n : map ppr vs)

valueShape :: Value -> ValueShape
valueShape (ValueArray shape _) = shape
valueShape (ValueRecord fs) = ShapeRecord $ M.map valueShape fs
valueShape (ValueSum shape _ _) = shape
valueShape _ = ShapeLeaf

checkShape :: Shape (Maybe Int32) -> ValueShape -> Maybe ValueShape
checkShape (ShapeDim Nothing shape1) (ShapeDim d2 shape2) =
  ShapeDim d2 <$> checkShape shape1 shape2
checkShape (ShapeDim (Just d1) shape1) (ShapeDim d2 shape2) = do
  guard $ d1 == d2
  ShapeDim d2 <$> checkShape shape1 shape2
checkShape (ShapeDim d1 shape1) ShapeLeaf =
  -- This case is for handling polymorphism, when a function doesn't
  -- know that the array it produced actually has more dimensions.
  ShapeDim (fromMaybe 0 d1) <$> checkShape shape1 ShapeLeaf
checkShape (ShapeRecord shapes1) (ShapeRecord shapes2) =
  ShapeRecord <$> sequence (M.intersectionWith checkShape shapes1 shapes2)
checkShape (ShapeRecord shapes1) ShapeLeaf =
  Just $ fromMaybe 0 <$> ShapeRecord shapes1
checkShape (ShapeSum shapes1) (ShapeSum shapes2) =
  ShapeSum <$> sequence (M.intersectionWith (zipWithM checkShape) shapes1 shapes2)
checkShape (ShapeSum shapes1) ShapeLeaf =
  Just $ fromMaybe 0 <$> ShapeSum shapes1
checkShape _ shape2 =
  Just shape2

imposeShape :: ValueShape -> Value -> Value
imposeShape (ShapeDim d shape1) (ValueArray _ arr) =
  ValueArray (ShapeDim d shape1) $ fmap (imposeShape shape1) arr
imposeShape (ShapeRecord shapes) (ValueRecord fs) =
  ValueRecord $ M.intersectionWith imposeShape shapes fs
imposeShape (ShapeSum shapes) (ValueSum _ c vs)
  | Just c_shapes <- M.lookup c shapes =
      ValueSum (ShapeSum shapes) c $ zipWith imposeShape c_shapes vs
imposeShape _ v =
  v

matchDims :: Shape (DimDecl VName) -> ValueShape -> M.Map VName Int32
matchDims (ShapeDim d1 shape1) (ShapeDim d2 shape2) =
  match d1 <> matchDims shape1 shape2
  where match (NamedDim (QualName [] v)) = M.singleton v d2
        match _                          = mempty
matchDims (ShapeRecord shapes1) (ShapeRecord shapes2) =
  mconcat $ M.elems $ M.intersectionWith matchDims shapes1 shapes2
matchDims (ShapeSum shapes1) (ShapeSum shapes2) =
  mconcat $ M.elems $ M.map (mconcat . map (uncurry matchDims)) $
  M.intersectionWith zip shapes1 shapes2
matchDims _ _ =
  mempty

matchTypeShapes :: StructType -> ValueShape -> M.Map VName ValueShape
matchTypeShapes (Array _ _ et tshape) vshape =
  matchTypeShapes (Scalar et) $ stripShapeDims (shapeRank tshape) vshape
matchTypeShapes (Scalar (TypeVar _ _ tname [])) vshape =
  M.singleton (typeLeaf tname) vshape
matchTypeShapes (Scalar (Record tfields)) (ShapeRecord vfields) =
  fold $ M.intersectionWith matchTypeShapes tfields vfields
matchTypeShapes (Scalar (Sum tconstrs)) (ShapeSum vconstrs) =
  fold $ fold $ M.intersectionWith (zipWith matchTypeShapes) tconstrs vconstrs
matchTypeShapes _ _ = mempty

-- | Does the value correspond to an empty array?
isEmptyArray :: Value -> Bool
isEmptyArray = emptyShape . valueShape

-- | String representation of an empty array with the provided element
-- type.  This is pretty ad-hoc - don't expect good results unless the
-- element type is a primitive.
prettyEmptyArray :: TypeBase () () -> Value -> String
prettyEmptyArray t v =
  "empty(" ++ dims (valueShape v) ++ pretty t ++ ")"
  where dims (ShapeDim n rowshape) =
          "[" ++ pretty n ++ "]" ++ dims rowshape
        dims _ = ""

-- | Create an array value; failing if that would result in an
-- irregular array.
mkArray :: TypeBase Int32 () -> [Value] -> Maybe Value
mkArray t [] =
  return $ toArray (typeShape mempty t) []
mkArray _ (v:vs) = do
  let v_shape = valueShape v
  guard $ all ((==v_shape) . valueShape) vs
  return $ toArray' v_shape $ v:vs

arrayLength :: Integral int => Array Int Value -> int
arrayLength = fromIntegral . (+1) . snd . bounds

toTuple :: [Value] -> Value
toTuple = ValueRecord . M.fromList . zip tupleFieldNames

fromTuple :: Value -> Maybe [Value]
fromTuple (ValueRecord m) = areTupleFields m
fromTuple _ = Nothing

asInteger :: Value -> Integer
asInteger (ValuePrim (SignedValue v)) = P.valueIntegral v
asInteger (ValuePrim (UnsignedValue v)) =
  toInteger (P.valueIntegral (P.doZExt v Int64) :: Word64)
asInteger v = error $ "Unexpectedly not an integer: " ++ pretty v

asInt :: Value -> Int
asInt = fromIntegral . asInteger

asSigned :: Value -> IntValue
asSigned (ValuePrim (SignedValue v)) = v
asSigned v = error $ "Unexpected not a signed integer: " ++ pretty v

asInt32 :: Value -> Int32
asInt32 = fromIntegral . asInteger

asBool :: Value -> Bool
asBool (ValuePrim (BoolValue x)) = x
asBool v = error $ "Unexpectedly not a boolean: " ++ pretty v

lookupInEnv :: (Env -> M.Map VName x)
            -> QualName VName -> Env -> Maybe x
lookupInEnv onEnv qv env = f env $ qualQuals qv
  where f m (q:qs) =
          case M.lookup q $ envTerm m of
            Just (TermModule (Module mod)) -> f mod qs
            _ -> Nothing
        f m [] = M.lookup (qualLeaf qv) $ onEnv m

lookupVar :: QualName VName -> Env -> Maybe TermBinding
lookupVar = lookupInEnv envTerm

lookupType :: QualName VName -> Env -> Maybe T.TypeBinding
lookupType = lookupInEnv envType

-- | A TermValue with a 'Nothing' type annotation is an intrinsic.
data TermBinding = TermValue (Maybe T.BoundV) Value
                 | TermModule Module

data Module = Module Env
            | ModuleFun (Module -> EvalM Module)

data Env = Env { envTerm :: M.Map VName TermBinding
               , envType :: M.Map VName T.TypeBinding
               , envShapes :: M.Map VName ValueShape
                 -- ^ A mapping from type parameters to the shapes of
                 -- the value to which they were initially bound.
               }

instance Monoid Env where
  mempty = Env mempty mempty mempty

instance Semigroup Env where
  Env vm1 tm1 sm1 <> Env vm2 tm2 sm2 =
    Env (vm1 <> vm2) (tm1 <> tm2) (sm1 <> sm2)

newtype InterpreterError = InterpreterError String

valEnv :: M.Map VName (Maybe T.BoundV, Value) -> Env
valEnv m = Env { envTerm = M.map (uncurry TermValue) m
               , envType = mempty
               , envShapes = mempty
               }

modEnv :: M.Map VName Module -> Env
modEnv m = Env { envTerm = M.map TermModule m
               , envType = mempty
               , envShapes = mempty
               }

typeEnv :: M.Map VName StructType -> Env
typeEnv m = Env { envTerm = mempty
                , envType = M.map tbind m
                , envShapes = mempty
                }
  where tbind = T.TypeAbbr Unlifted []


shapeEnv :: M.Map VName ValueShape -> Env
shapeEnv m = Env { envTerm = mempty
                 , envType = mempty
                 , envShapes = m
                 }

instance Show InterpreterError where
  show (InterpreterError s) = s

bad :: SrcLoc -> Env -> String -> EvalM a
bad loc env s = stacking loc env $ do
  ss <- map locStr <$> stacktrace
  liftF $ ExtOpError $ InterpreterError $ "Error at\n" ++ prettyStacktrace ss ++ s

trace :: Value -> EvalM ()
trace v = do
  -- We take the second-to-last element of the stack, because any
  -- actual call to 'implicits.trace' is going to be in the trace
  -- function in the prelude, which is not interesting.
  top <- fromMaybe noLoc . maybeHead . drop 1 . reverse <$> stacktrace
  liftF $ ExtOpTrace top (pretty v) ()

typeCheckerEnv :: Env -> T.Env
typeCheckerEnv env =
  -- FIXME: some shadowing issues are probably not right here.
  let valMap (TermValue (Just t) _) = Just t
      valMap _ = Nothing
      vtable = M.mapMaybe valMap $ envTerm env
      nameMap k | k `M.member` vtable = Just ((T.Term, baseName k), qualName k)
                | otherwise = Nothing
  in mempty { T.envNameMap = M.fromList $ mapMaybe nameMap $ M.keys $ envTerm env
            , T.envVtable = vtable }

break :: EvalM ()
break = do
  -- We don't want the env of the function that is calling
  -- intrinsics.break, since that is just going to be the boring
  -- wrapper function (intrinsics are never called directly).
  -- This is why we go a step up the stack.
  stack <- asks $ drop 1 . fst
  case stack of
    [] -> return ()
    top:_ -> do
      let env = stackFrameEnv top
      imports <- asks snd
      liftF $ ExtOpBreak
        (map stackFrameSrcLoc $ reverse stack)
        (Ctx env imports) (typeCheckerEnv env) ()

fromArray :: Value -> (ValueShape, [Value])
fromArray (ValueArray shape as) = (shape, elems as)
fromArray v = error $ "Expected array value, but found: " ++ pretty v

toArray :: ValueShape -> [Value] -> Value
toArray shape vs = ValueArray shape (listArray (0, length vs - 1) vs)

toArray' :: ValueShape -> [Value] -> Value
toArray' rowshape vs = ValueArray shape (listArray (0, length vs - 1) vs)
  where shape = ShapeDim (genericLength vs) rowshape

apply :: SrcLoc -> Env -> Value -> Value -> EvalM Value
apply loc env (ValueFun rt f) v = stacking loc env (f v)
apply _ _ f _ = error $ "Cannot apply non-function: " ++ pretty f

apply2 :: SrcLoc -> Env -> Value -> Value -> Value -> EvalM Value
apply2 loc env f x y = stacking loc env $ do f' <- apply noLoc mempty f x
                                             apply noLoc mempty f' y

matchPattern :: Env -> Pattern -> Value -> EvalM Env
matchPattern env p v = do
  m <- runMaybeT $ patternMatch env p v
  case m of
    Nothing   -> error $ "matchPattern: missing case for " ++ pretty p ++ " and " ++ pretty v
    Just env' -> return env'

dimsEnv :: StructType -> ValueShape -> Env
dimsEnv t shape =
  valEnv (M.map f $ matchDims (typeShape mempty t) shape)
  where f d = (Just $ T.BoundV [] $ Scalar $ Prim $ Signed Int32,
               ValuePrim $ SignedValue $ Int32Value d)

paramEnv :: StructType -> ValueShape -> Env
paramEnv t shape =
  dimsEnv t shape <> shapeEnv (matchTypeShapes t shape)

patternMatch :: Env -> Pattern -> Value -> MaybeT EvalM Env
patternMatch env (Id v (Info t) _) val =
  lift $ pure $
  valEnv (M.singleton v (Just $ T.BoundV [] $ toStruct t, val)) <>
  paramEnv (evalType env (toStruct t)) (valueShape val) <>
  env
patternMatch env (Wildcard (Info t) _) v =
  lift $ pure $ paramEnv (evalType env (toStruct t)) (valueShape v) <> env
patternMatch env (TuplePattern ps _) (ValueRecord vs)
  | length ps == length vs' =
      foldM (\env' (p,v) -> patternMatch env' p v) env $
      zip ps (map snd $ sortFields vs)
    where vs' = sortFields vs
patternMatch env (RecordPattern ps _) (ValueRecord vs)
  | length ps == length vs' =
      foldM (\env' (p,v) -> patternMatch env' p v) env $
      zip (map snd $ sortFields $ M.fromList ps) (map snd $ sortFields vs)
    where vs' = sortFields vs
patternMatch env (PatternParens p _) v = patternMatch env p v
patternMatch env (PatternAscription p _ _) v =
  patternMatch env p v
patternMatch env (PatternLit e _ _) v = do
  v' <- lift $ eval env e
  if v == v'
    then pure env
    else mzero
patternMatch env (PatternConstr n _ ps _) (ValueSum _ n' vs)
  | n == n' =
      foldM (\env' (p,v) -> patternMatch env' p v) env $ zip ps vs
patternMatch _ _ _ = mzero

data Indexing = IndexingFix Int32
              | IndexingSlice (Maybe Int32) (Maybe Int32) (Maybe Int32)

instance Pretty Indexing where
  ppr (IndexingFix i) = ppr i
  ppr (IndexingSlice i j (Just s)) =
    maybe mempty ppr i <> text ":" <>
    maybe mempty ppr j <> text ":" <>
    ppr s
  ppr (IndexingSlice i (Just j) s) =
    maybe mempty ppr i <> text ":" <>
    ppr j <>
    maybe mempty ((text ":" <>) . ppr) s
  ppr (IndexingSlice i Nothing Nothing) =
    maybe mempty ppr i <> text ":"

indexesFor :: Maybe Int32 -> Maybe Int32 -> Maybe Int32
           -> Int32 -> Maybe [Int]
indexesFor start end stride n
  | (start', end', stride') <- slice,
    end' == start' || signum' (end' - start') == signum' stride',
    stride' /= 0,
    is <- [start', start'+stride' .. end'-signum stride'],
    all inBounds is =
      Just $ map fromIntegral is
  | otherwise =
      Nothing
  where inBounds i = i >= 0 && i < n

        slice =
          case (start, end, stride) of
            (Just start', _, _) ->
              let end' = fromMaybe n end
              in (start', end', fromMaybe 1 stride)
            (Nothing, Just end', _) ->
              let start' = 0
              in (start', end', fromMaybe 1 stride)
            (Nothing, Nothing, Just stride') ->
              (if stride' > 0 then 0 else n-1,
               if stride' > 0 then n else -1,
               stride')
            (Nothing, Nothing, Nothing) ->
              (0, n, 1)

-- | 'signum', but with 0 as 1.
signum' :: (Eq p, Num p) => p -> p
signum' 0 = 1
signum' x = signum x

indexShape :: [Indexing] -> ValueShape -> ValueShape
indexShape (IndexingFix{}:is) (ShapeDim _ shape) =
  indexShape is shape
indexShape (IndexingSlice start end stride:is) (ShapeDim d shape) =
  ShapeDim n $ indexShape is shape
  where n = maybe 0 genericLength $ indexesFor start end stride d
indexShape _ shape =
  shape

indexArray :: [Indexing] -> Value -> Maybe Value
indexArray (IndexingFix i:is) (ValueArray _ arr)
  | i >= 0, i < n =
      indexArray is $ arr ! fromIntegral i
  | otherwise =
      Nothing
  where n = arrayLength arr
indexArray (IndexingSlice start end stride:is) (ValueArray (ShapeDim _ rowshape) arr) = do
  js <- indexesFor start end stride $ arrayLength arr
  toArray' (indexShape is rowshape) <$> mapM (indexArray is . (arr!)) js
indexArray _ v = Just v

updateArray :: [Indexing] -> Value -> Value -> Maybe Value
updateArray (IndexingFix i:is) (ValueArray shape arr) v
  | i >= 0, i < n = do
      v' <- updateArray is (arr ! i') v
      Just $ ValueArray shape $ arr // [(i', v')]
  | otherwise =
      Nothing
  where n = arrayLength arr
        i' = fromIntegral i
updateArray (IndexingSlice start end stride:is) (ValueArray shape arr) (ValueArray _ v) = do
  arr_is <- indexesFor start end stride $ arrayLength arr
  guard $ length arr_is == arrayLength v
  let update arr' (i, v') = do
        x <- updateArray is (arr!i) v'
        return $ arr' // [(i, x)]
  fmap (ValueArray shape) $ foldM update arr $ zip arr_is $ elems v
updateArray _ _ v = Just v

evalDimIndex :: Env -> DimIndex -> EvalM Indexing
evalDimIndex env (DimFix x) =
  IndexingFix . asInt32 <$> eval env x
evalDimIndex env (DimSlice start end stride) =
  IndexingSlice <$> traverse (fmap asInt32 . eval env) start
                <*> traverse (fmap asInt32 . eval env) end
                <*> traverse (fmap asInt32 . eval env) stride

evalIndex :: SrcLoc -> Env -> [Indexing] -> Value -> EvalM Value
evalIndex loc env is arr = do
  let oob = bad loc env $ "Index [" <> intercalate ", " (map pretty is) <>
            "] out of bounds for array of shape " <>
            pretty (valueShape arr) <> "."
  maybe oob return $ indexArray is arr

-- | Expand type based on information that was not available at
-- type-checking time (the structure of abstract types).
evalType :: Env -> StructType -> StructType
evalType _ (Scalar (Prim pt)) = Scalar $ Prim pt
evalType env (Scalar (Record fs)) = Scalar $ Record $ fmap (evalType env) fs
evalType env (Scalar (Arrow () p t1 t2)) =
  Scalar $ Arrow () p (evalType env t1) (evalType env t2)
evalType env t@(Array _ u _ shape) =
  let et = stripArray (shapeRank shape) t
      et' = evalType env et
      shape' = fmap evalDim shape
  in arrayOf et' shape' u
  where evalDim (NamedDim qn)
          | Just (TermValue _ (ValuePrim (SignedValue (Int32Value x)))) <-
              lookupVar qn env =
              ConstDim $ fromIntegral x
        evalDim d = d
evalType env t@(Scalar (TypeVar () _ tn args)) =
  case lookupType (qualNameFromTypeName tn) env of
    Just (T.TypeAbbr _ ps t') ->
      let (substs, types) = mconcat $ zipWith matchPtoA ps args
          onDim (NamedDim v) = fromMaybe (NamedDim v) $ M.lookup (qualLeaf v) substs
          onDim d = d
      in if null ps then first onDim t'
         else evalType (Env mempty types mempty <> env) $ first onDim t'
    Nothing -> t

  where matchPtoA (TypeParamDim p _) (TypeArgDim (NamedDim qv) _) =
          (M.singleton p $ NamedDim qv, mempty)
        matchPtoA (TypeParamDim p _) (TypeArgDim (ConstDim k) _) =
          (M.singleton p $ ConstDim k, mempty)
        matchPtoA (TypeParamType l p _) (TypeArgType t' _) =
          let t'' = evalType env t'
          in (mempty, M.singleton p $ T.TypeAbbr l [] t'')
        matchPtoA _ _ = mempty
evalType env (Scalar (Sum cs)) = Scalar $ Sum $ (fmap . fmap) (evalType env) cs

evalTypeFully :: Env -> TypeBase (DimDecl VName) als -> Maybe ValueType
evalTypeFully env = bitraverse onDim pure . evalType env . toStruct
  where onDim (ConstDim x) = Just $ fromIntegral x
        onDim _            = Nothing

evalTermVar :: Env -> QualName VName -> StructType -> EvalM Value
evalTermVar env qv t =
  case (lookupVar qv env, evalTypeFully env t) of
--    (Just (TermValue tparams (ValueFun Nothing f)),
--     Just (Scalar (Arrow _ _ _ rt))) -> return $ ValueFun (Just rt) f
    (Just (TermValue _ v), _) -> return v
    _ -> error $ "`" <> pretty qv <> "` is not bound to a value."

typeValueShape :: Env -> StructType -> ValueShape
typeValueShape env = fmap dim . typeShape mempty . evalType env
  where dim (ConstDim x) = fromIntegral x
        dim d = error $ "nope: " ++ show d

returnTypeShape env rettype =
  typeShape (envShapes env) <$> evalTypeFully env rettype

valueFun :: Env
         -> StructType -> StructType
         -> (Value -> EvalM Value)
         -> EvalM Value
valueFun env ptype rettype m =
--  Debug.Trace.trace (unlines [show ptype, show rettype]) $
  return $ ValueFun ((const <$> returnTypeShape env rettype) `mplus` match) m
  where ptype_dims = nestedDims ptype
        match
          | all (`elem` ptype_dims) $ nestedDims rettype =
              Just $ \pshape ->
              let env' = paramEnv ptype pshape <> env
              in typeValueShape env' rettype
          | otherwise = Nothing

evalFunction :: Env -> [Pattern] -> Exp -> StructType -> EvalM Value

-- We treat zero-parameter lambdas as simply an expression to
-- evaluate immediately.  Note that this is *not* the same as a lambda
-- that takes an empty tuple '()' as argument!  Zero-parameter lambdas
-- can never occur in a well-formed Futhark program, but they are
-- convenient in the interpreter.
evalFunction env [] body rettype =
  -- Eta-expand the rest to make any sizes visible.
  etaExpand [] env rettype
  where etaExpand vs env' (Scalar (Arrow _ _ pt rt)) =
          return $ ValueFun Nothing $ \v -> do
          env'' <- matchPattern env' (Wildcard (Info $ fromStruct pt) noLoc) v
          etaExpand (v:vs) env'' rt
        etaExpand vs env' _ = do
          f <- eval env' body
          foldM (apply noLoc mempty) f $ reverse vs

evalFunction env (p:ps) body rettype =
  valueFun env (patternStructType p) rettype $ \v -> do
    env' <- matchPattern env p v
    evalFunction env' ps body rettype

postApply :: SrcLoc -> Env -> Value -> PatternType -> EvalM Value
postApply loc env v t = return v
postApply loc env v t = do
  let t' = evalType env $ toStruct t
  case checkShape (structTypeShape (envShapes env) t') (valueShape v) of
    Nothing -> fail $ unlines ["Unexpected return value at " ++ locStr loc,
                               "Value shape: " ++ pretty (valueShape v),
--                               "Expected shape: " ++ pretty (structTypeShape t'),
                               show t, show t']
    Just shape -> do
      let msg = unlines ["application: " ++ locStr loc,
--                         "value: " ++ pretty v,
--                         "return shape: " ++ show (structTypeShape t'),
                         "value shape: " ++ show (valueShape v),
                         "combined/imposing shape: " ++ show shape,
                         "resulting value shape: " ++ pretty (valueShape $ imposeShape shape v)]
      return $ imposeShape shape v

eval :: Env -> Exp -> EvalM Value

eval _ (Literal v _) = return $ ValuePrim v

eval env (Parens e _ ) = eval env e

eval env (QualParens _ e _ ) = eval env e

eval env (TupLit vs _) = toTuple <$> mapM (eval env) vs

eval env (RecordLit fields _) =
  ValueRecord . M.fromList <$> mapM evalField fields
  where evalField (RecordFieldExplicit k e _) = do
          v <- eval env e
          return (k, v)
        evalField (RecordFieldImplicit k t loc) = do
          v <- eval env $ Var (qualName k) t loc
          return (baseName k, v)

eval env (ArrayLit [] (Info t) _) =
  return $ toArray (typeValueShape env $ toStruct t) []

eval env (ArrayLit (v:vs) _ _) = do
  v' <- eval env v
  vs' <- mapM (eval env) vs
  return $ toArray' (valueShape v') (v':vs')

eval env (Range start maybe_second end (Info t) _) = do
  start' <- asInteger <$> eval env start
  maybe_second' <- traverse (fmap asInteger . eval env) maybe_second
  (end', dir) <- case end of
    DownToExclusive e -> (,-1) . (+1) . asInteger <$> eval env e
    ToInclusive e -> (,maybe 1 (signum . subtract start') maybe_second') .
                     asInteger <$> eval env e
    UpToExclusive e -> (,1) . subtract 1 . asInteger <$> eval env e

  let second = fromMaybe (start' + dir) maybe_second'
      step = second - start'
  return $
    if step == 0 || dir /= signum step
    then toArray' ShapeLeaf []
    else toArray' ShapeLeaf $ map toInt [start',second..end']

  where toInt =
          case stripArray 1 t of
            Scalar (Prim (Signed t')) ->
              ValuePrim . SignedValue . intValue t'
            Scalar (Prim (Unsigned t')) ->
              ValuePrim . UnsignedValue . intValue t'
            _ -> error $ "Nonsensical range type: " ++ show t

eval env (Var qv (Info t) _) = evalTermVar env qv (toStruct t)

eval env (Ascript e td _ loc) = do
  v <- eval env e
  let t = evalType env $ unInfo $ expandedType td
  case checkShape (structTypeShape (envShapes env) t) (valueShape v) of
    Just _ -> return v
    Nothing ->
      bad loc env $ "Value `" <> pretty v <> "` of shape `" ++ pretty (valueShape v) ++
      "` cannot match shape of type `" <>
      pretty (declaredType td) <> "` (`" <> pretty t <> "`)"

eval env (LetPat p e body _ _) = do
  v <- eval env e
  env' <- matchPattern env p v
  eval env' body

eval env (LetFun f (_, pats, _, Info ret, fbody) body _) = do
  v <- evalFunction env pats fbody ret
  let arrow (xp, xt) yt = Scalar $ Arrow () xp xt yt
      ftype = T.BoundV [] $ foldr (arrow . patternParam) ret pats
  eval (valEnv (M.singleton f (Just ftype, v)) <> env) body

eval _ (IntLit v (Info t) _) =
  case t of
    Scalar (Prim (Signed it)) ->
      return $ ValuePrim $ SignedValue $ intValue it v
    Scalar (Prim (Unsigned it)) ->
      return $ ValuePrim $ UnsignedValue $ intValue it v
    Scalar (Prim (FloatType ft)) ->
      return $ ValuePrim $ FloatValue $ floatValue ft v
    _ -> error $ "eval: nonsensical type for integer literal: " ++ pretty t

eval _ (FloatLit v (Info t) _) =
  case t of
    Scalar (Prim (FloatType ft)) ->
      return $ ValuePrim $ FloatValue $ floatValue ft v
    _ -> error $ "eval: nonsensical type for float literal: " ++ pretty t

eval env (BinOp (op, _) op_t (x, _) (y, _) (Info t) loc)
  | baseString (qualLeaf op) == "&&" = do
      x' <- asBool <$> eval env x
      if x'
        then eval env y
        else return $ ValuePrim $ BoolValue False
  | baseString (qualLeaf op) == "||" = do
      x' <- asBool <$> eval env x
      if x'
        then return $ ValuePrim $ BoolValue True
        else eval env y
  | otherwise = do
      op' <- eval env $ Var op op_t loc
      x' <- eval env x
      y' <- eval env y
      v <- apply2 loc env op' x' y'
      postApply loc env v t

eval env (If cond e1 e2 _ _) = do
  cond' <- asBool <$> eval env cond
  if cond' then eval env e1 else eval env e2

eval env (Apply f x _ (Info t) loc) = do
  f' <- eval env f
  x' <- eval env x
  let msg = unlines ["apply", take 100 (pretty f), pretty f', pretty x']
  v <- apply loc env f' x'
  postApply loc env v t

eval env (Negate e _) = do
  ev <- eval env e
  ValuePrim <$> case ev of
    ValuePrim (SignedValue (Int8Value v)) -> return $ SignedValue $ Int8Value (-v)
    ValuePrim (SignedValue (Int16Value v)) -> return $ SignedValue $ Int16Value (-v)
    ValuePrim (SignedValue (Int32Value v)) -> return $ SignedValue $ Int32Value (-v)
    ValuePrim (SignedValue (Int64Value v)) -> return $ SignedValue $ Int64Value (-v)
    ValuePrim (UnsignedValue (Int8Value v)) -> return $ UnsignedValue $ Int8Value (-v)
    ValuePrim (UnsignedValue (Int16Value v)) -> return $ UnsignedValue $ Int16Value (-v)
    ValuePrim (UnsignedValue (Int32Value v)) -> return $ UnsignedValue $ Int32Value (-v)
    ValuePrim (UnsignedValue (Int64Value v)) -> return $ UnsignedValue $ Int64Value (-v)
    ValuePrim (FloatValue (Float32Value v)) -> return $ FloatValue $ Float32Value (-v)
    ValuePrim (FloatValue (Float64Value v)) -> return $ FloatValue $ Float64Value (-v)
    _ -> fail $ "Cannot negate " ++ pretty ev

eval env (Index e is _ loc) = do
  is' <- mapM (evalDimIndex env) is
  arr <- eval env e
  evalIndex loc env is' arr

eval env (Update src is v loc) =
  maybe oob return =<<
  updateArray <$> mapM (evalDimIndex env) is <*> eval env src <*> eval env v
  where oob = bad loc env "Bad update"

eval env (RecordUpdate src all_fs v _ _) =
  update <$> eval env src <*> pure all_fs <*> eval env v
  where update _ [] v' = v'
        update (ValueRecord src') (f:fs) v'
          | Just f_v <- M.lookup f src' =
              ValueRecord $ M.insert f (update f_v fs v') src'
        update _ _ _ = error "eval RecordUpdate: invalid value."

eval env (LetWith dest src is v body _ loc) = do
  let Ident src_vn (Info src_t) _ = src
  dest' <- maybe oob return =<<
    updateArray <$> mapM (evalDimIndex env) is <*>
    evalTermVar env (qualName src_vn) (toStruct src_t) <*> eval env v
  let t = T.BoundV [] $ toStruct $ unInfo $ identType dest
  eval (valEnv (M.singleton (identName dest) (Just t, dest')) <> env) body
  where oob = bad loc env "Bad update"

-- We treat zero-parameter lambdas as simply an expression to
-- evaluate immediately.  Note that this is *not* the same as a lambda
-- that takes an empty tuple '()' as argument!  Zero-parameter lambdas
-- can never occur in a well-formed Futhark program, but they are
-- convenient in the interpreter.
eval env (Lambda ps body _ (Info (_, rt)) _) =
  Debug.Trace.trace (pretty (unwords ["lambda return", pretty rt, pretty (evalType env rt)])) evalFunction env ps body rt

eval env (OpSection qv (Info t) _) = evalTermVar env qv $ toStruct t

eval env (OpSectionLeft qv _ e _ (Info t) loc) = do
  v <- join $ apply loc env <$> evalTermVar env qv (toStruct t) <*> eval env e
  postApply loc env v t

eval env (OpSectionRight qv _ e (Info ptype, Info rettype) (Info t) loc) = do
  f <- evalTermVar env qv $ toStruct t
  y <- eval env e
  Debug.Trace.trace (unlines [show rettype, show (returnTypeShape env rettype)]) $ valueFun env ptype rettype $ \x -> do
    v <- join $ apply loc env <$> apply loc env f x <*> pure y
    postApply loc env v t

eval env (IndexSection is _ loc) = do
  is' <- mapM (evalDimIndex env) is
  return $ ValueFun Nothing $ evalIndex loc env is'

eval _ (ProjectSection ks _ _) =
  return $ ValueFun (Just $ projectShape ks) $ flip (foldM walk) ks
  where walk (ValueRecord fs) f
          | Just v' <- M.lookup f fs = return v'
        walk _ _ = fail "Value does not have expected field."

eval env (DoLoop pat init_e form body _) = do
  init_v <- eval env init_e
  case form of For iv bound -> do
                 bound' <- asSigned <$> eval env bound
                 forLoop (identName iv) bound' (zero bound') init_v
               ForIn in_pat in_e -> do
                 (_, in_vs) <- fromArray <$> eval env in_e
                 foldM (forInLoop in_pat) init_v in_vs
               While cond ->
                 whileLoop cond init_v
  where withLoopParams = matchPattern env pat

        inc = (`P.doAdd` Int64Value 1)
        zero = (`P.doMul` Int64Value 0)

        forLoop iv bound i v
          | i >= bound = return v
          | otherwise = do
              env' <- withLoopParams v
              forLoop iv bound (inc i) =<<
                eval (valEnv (M.singleton iv (Just $ T.BoundV [] $ Scalar $ Prim $ Signed Int32,
                                              ValuePrim (SignedValue i))) <> env') body

        whileLoop cond v = do
          env' <- withLoopParams v
          continue <- asBool <$> eval env' cond
          if continue
            then whileLoop cond =<< eval env' body
            else return v

        forInLoop in_pat v in_v = do
          env' <- withLoopParams v
          env'' <- matchPattern env' in_pat in_v
          eval env'' body

eval env (Project f e _ _) = do
  v <- eval env e
  case v of
    ValueRecord fs | Just v' <- M.lookup f fs -> return v'
    _ -> fail "Value does not have expected field."

eval env (Unsafe e _) = eval env e

eval env (Assert what e (Info s) loc) = do
  cond <- asBool <$> eval env what
  unless cond $ bad loc env s
  eval env e

eval env (Constr c es (Info t) _) = do
  vs <- mapM (eval env) es
  return $ ValueSum (typeValueShape env $ toStruct t) c vs

eval env (Match e cs _ _) = do
  v <- eval env e
  match v $ NE.toList cs
  where match _ [] =
          fail "Pattern match failure."
        match v (c:cs') = do
          c' <- evalCase v env c
          case c' of
            Just v' -> return v'
            Nothing -> match v cs'

evalCase :: Value -> Env -> CaseBase Info VName
         -> EvalM (Maybe Value)
evalCase v env (CasePat p cExp _) = runMaybeT $ do
  env' <- patternMatch env p v
  lift $ eval env' cExp

substituteInModule :: M.Map VName VName -> Module -> Module
substituteInModule substs = onModule
  where
    rev_substs = reverseSubstitutions substs
    replace v = fromMaybe v $ M.lookup v rev_substs
    replaceQ v = maybe v qualName $ M.lookup (qualLeaf v) rev_substs
    replaceM f m = M.fromList $ do
      (k, v) <- M.toList m
      return (replace k, f v)
    onModule (Module (Env terms types _)) =
      Module $ Env (replaceM onTerm terms) (replaceM onType types) mempty
    onModule (ModuleFun f) =
      ModuleFun $ \m -> onModule <$> f (substituteInModule rev_substs m)
    onTerm (TermValue t v) = TermValue t v
    onTerm (TermModule m) = TermModule $ onModule m
    onType (T.TypeAbbr l ps t) = T.TypeAbbr l ps $ first onDim t
    onDim (NamedDim v) = NamedDim $ replaceQ v
    onDim (ConstDim x) = ConstDim x
    onDim AnyDim = AnyDim

reverseSubstitutions :: M.Map VName VName -> M.Map VName VName
reverseSubstitutions = M.fromList . map (uncurry $ flip (,)) . M.toList

evalModuleVar :: Env -> QualName VName -> EvalM Module
evalModuleVar env qv =
  case lookupVar qv env of
    Just (TermModule m) -> return m
    _ -> error $ quote (pretty qv) <> " is not bound to a module."

evalModExp :: Env -> ModExp -> EvalM Module

evalModExp _ (ModImport _ (Info f) _) = do
  f' <- lookupImport f
  case f' of Nothing -> error $ "Unknown import " ++ show f
             Just m -> return $ Module m

evalModExp env (ModDecs ds _) = do
  Env terms types _ <- foldM evalDec env ds
  -- Remove everything that was present in the original Env.
  return $ Module $ Env (terms `M.difference` envTerm env)
                        (types `M.difference` envType env)
                        mempty

evalModExp env (ModVar qv _) =
  evalModuleVar env qv

evalModExp env (ModAscript me _ (Info substs) _) =
  substituteInModule substs <$> evalModExp env me

evalModExp env (ModParens me _) = evalModExp env me

evalModExp env (ModLambda p ret e loc) =
  return $ ModuleFun $ \am -> do
  let env' = env { envTerm = M.insert (modParamName p) (TermModule am) $ envTerm env }
  evalModExp env' $ case ret of
    Nothing -> e
    Just (se, rsubsts) -> ModAscript e se rsubsts loc

evalModExp env (ModApply f e (Info psubst) (Info rsubst) _) = do
  ModuleFun f' <- evalModExp env f
  e' <- evalModExp env e
  substituteInModule rsubst <$> f' (substituteInModule psubst e')

evalDec :: Env -> Dec -> EvalM Env

evalDec env (ValDec (ValBind _ v _ (Info t) _ ps def _ _)) = do
  let t' = evalType env t
      arrow (xp, xt) yt = Scalar $ Arrow () xp xt yt
      ftype = T.BoundV [] $ foldr (arrow . patternParam) t' ps
  val <- evalFunction env ps def t'
  return $ valEnv (M.singleton v (Just ftype, val)) <> env

evalDec env (OpenDec me _) = do
  Module me' <- evalModExp env me
  return $ me' <> env

evalDec env (ImportDec name name' loc) =
  evalDec env $ LocalDec (OpenDec (ModImport name name' loc) loc) loc

evalDec env (LocalDec d _) = evalDec env d
evalDec env SigDec{} = return env
evalDec env (TypeDec (TypeBind v ps t _ _)) = do
  let abbr = T.TypeAbbr Lifted ps $
             evalType env $ unInfo $ expandedType t
  return env { envType = M.insert v abbr $ envType env }
evalDec env (ModDec (ModBind v ps ret body _ loc)) = do
  mod <- evalModExp env $ wrapInLambda ps
  return $ modEnv (M.singleton v mod) <> env
  where wrapInLambda [] = case ret of
                            Just (se, substs) -> ModAscript body se substs loc
                            Nothing           -> body
        wrapInLambda [p] = ModLambda p ret body loc
        wrapInLambda (p:ps') = ModLambda p Nothing (wrapInLambda ps') loc

data Ctx = Ctx { ctxEnv :: Env
               , ctxImports :: M.Map FilePath Env
               }

-- | The initial environment contains definitions of the various intrinsic functions.
initialCtx :: Ctx
initialCtx =
  Ctx (Env (M.insert (VName (nameFromString "intrinsics") 0)
            (TermModule (Module $ Env terms types mempty)) terms)
        types mempty)
      mempty
  where
    terms = M.mapMaybeWithKey (const . def . baseString) intrinsics
    types = M.mapMaybeWithKey (const . tdef . baseString) intrinsics

    sintOp f = [ (getS, putS, P.doBinOp (f Int8))
               , (getS, putS, P.doBinOp (f Int16))
               , (getS, putS, P.doBinOp (f Int32))
               , (getS, putS, P.doBinOp (f Int64))]
    uintOp f = [ (getU, putU, P.doBinOp (f Int8))
               , (getU, putU, P.doBinOp (f Int16))
               , (getU, putU, P.doBinOp (f Int32))
               , (getU, putU, P.doBinOp (f Int64))]
    intOp f = sintOp f ++ uintOp f
    floatOp f = [ (getF, putF, P.doBinOp (f Float32))
                , (getF, putF, P.doBinOp (f Float64))]
    arithOp f g = Just $ bopDef $ intOp f ++ floatOp g

    flipCmps = map (\(f, g, h) -> (f, g, flip h))
    sintCmp f = [ (getS, Just . BoolValue, P.doCmpOp (f Int8))
                , (getS, Just . BoolValue, P.doCmpOp (f Int16))
                , (getS, Just . BoolValue, P.doCmpOp (f Int32))
                , (getS, Just . BoolValue, P.doCmpOp (f Int64))]
    uintCmp f = [ (getU, Just . BoolValue, P.doCmpOp (f Int8))
                , (getU, Just . BoolValue, P.doCmpOp (f Int16))
                , (getU, Just . BoolValue, P.doCmpOp (f Int32))
                , (getU, Just . BoolValue, P.doCmpOp (f Int64))]
    floatCmp f = [ (getF, Just . BoolValue, P.doCmpOp (f Float32))
                 , (getF, Just . BoolValue, P.doCmpOp (f Float64))]
    boolCmp f = [ (getB, Just . BoolValue, P.doCmpOp f) ]

    getV (SignedValue x) = Just $ P.IntValue x
    getV (UnsignedValue x) = Just $ P.IntValue x
    getV (FloatValue x) = Just $ P.FloatValue x
    getV (BoolValue x) = Just $ P.BoolValue x
    putV (P.IntValue x) = SignedValue x
    putV (P.FloatValue x) = FloatValue x
    putV (P.BoolValue x) = BoolValue x
    putV P.Checked = BoolValue True

    getS (SignedValue x) = Just $ P.IntValue x
    getS _               = Nothing
    putS (P.IntValue x) = Just $ SignedValue x
    putS _              = Nothing

    getU (UnsignedValue x) = Just $ P.IntValue x
    getU _                 = Nothing
    putU (P.IntValue x) = Just $ UnsignedValue x
    putU _              = Nothing

    getF (FloatValue x) = Just $ P.FloatValue x
    getF _              = Nothing
    putF (P.FloatValue x) = Just $ FloatValue x
    putF _                = Nothing

    getB (BoolValue x) = Just $ P.BoolValue x
    getB _             = Nothing
    putB (P.BoolValue x) = Just $ BoolValue x
    putB _               = Nothing

    fun1 shape f =
      TermValue Nothing $ ValueFun shape $ \x -> f x
    fun2 shape f =
      TermValue Nothing $ ValueFun Nothing $ \x ->
      return $ ValueFun shape $ \y -> f x y
    fun2t f =
      TermValue Nothing $ ValueFun Nothing $ \v ->
      case fromTuple v of Just [x,y] -> f x y
                          _ -> error $ "Expected pair; got: " ++ pretty v
    fun3t f =
      TermValue Nothing $ ValueFun Nothing $ \v ->
      case fromTuple v of Just [x,y,z] -> f x y z
                          _ -> error $ "Expected triple; got: " ++ pretty v

    fun6t f =
      TermValue Nothing $ ValueFun Nothing $ \v ->
      case fromTuple v of Just [x,y,z,a,b,c] -> f x y z a b c
                          _ -> error $ "Expected sextuple; got: " ++ pretty v

    bopDef fs = fun2 (Just $ const ShapeLeaf) $ \x y ->
      case (x, y) of
        (ValuePrim x', ValuePrim y')
          | Just z <- msum $ map (`bopDef'` (x', y')) fs ->
              return $ ValuePrim z
        _ ->
          bad noLoc mempty $ "Cannot apply operator to arguments " <>
          quote (pretty x) <> " and " <> quote (pretty y) <> "."
      where bopDef' (valf, retf, op) (x, y) = do
              x' <- valf x
              y' <- valf y
              retf =<< op x' y'

    unopDef fs = fun1 (Just $ const ShapeLeaf) $ \x ->
      case x of
        (ValuePrim x')
          | Just r <- msum $ map (`unopDef'` x') fs ->
              return $ ValuePrim r
        _ ->
          bad noLoc mempty $ "Cannot apply function to argument " <>
          quote (pretty x) <> "."
      where unopDef' (valf, retf, op) x = do
              x' <- valf x
              retf =<< op x'

    tbopDef f = fun1 (Just $ const ShapeLeaf) $ \v ->
      case fromTuple v of
        Just [ValuePrim x, ValuePrim y]
          | Just x' <- getV x,
            Just y' <- getV y,
            Just z <- f x' y' ->
              return $ ValuePrim $ putV z
        _ ->
          bad noLoc mempty $ "Cannot apply operator to argument " <>
          quote (pretty v) <> "."

    def "!" = Just $ unopDef [ (getS, putS, P.doUnOp $ P.Complement Int8)
                             , (getS, putS, P.doUnOp $ P.Complement Int16)
                             , (getS, putS, P.doUnOp $ P.Complement Int32)
                             , (getS, putS, P.doUnOp $ P.Complement Int64)
                             , (getU, putU, P.doUnOp $ P.Complement Int8)
                             , (getU, putU, P.doUnOp $ P.Complement Int16)
                             , (getU, putU, P.doUnOp $ P.Complement Int32)
                             , (getU, putU, P.doUnOp $ P.Complement Int64)
                             , (getB, putB, P.doUnOp P.Not) ]

    def "+" = arithOp P.Add P.FAdd
    def "-" = arithOp P.Sub P.FSub
    def "*" = arithOp P.Mul P.FMul
    def "**" = arithOp P.Pow P.FPow
    def "/" = Just $ bopDef $ sintOp P.SDiv ++ uintOp P.UDiv ++ floatOp P.FDiv
    def "%" = Just $ bopDef $ sintOp P.SMod ++ uintOp P.UMod ++ floatOp P.FMod
    def "//" = Just $ bopDef $ sintOp P.SQuot ++ uintOp P.UDiv
    def "%%" = Just $ bopDef $ sintOp P.SRem ++ uintOp P.UMod
    def "^" = Just $ bopDef $ intOp P.Xor
    def "&" = Just $ bopDef $ intOp P.And
    def "|" = Just $ bopDef $ intOp P.Or
    def ">>" = Just $ bopDef $ sintOp P.AShr ++ uintOp P.LShr
    def "<<" = Just $ bopDef $ intOp P.Shl
    def ">>>" = Just $ bopDef $ sintOp P.LShr ++ uintOp P.LShr
    def "==" = Just $ fun2 (Just $ const ShapeLeaf) $
               \xs ys -> return $ ValuePrim $ BoolValue $ xs == ys
    def "!=" = Just $ fun2 (Just $ const ShapeLeaf) $
               \xs ys -> return $ ValuePrim $ BoolValue $ xs /= ys

    -- The short-circuiting is handled directly in 'eval'; these cases
    -- are only used when partially applying and such.
    def "&&" = Just $ fun2 (Just $ const ShapeLeaf) $ \x y ->
      return $ ValuePrim $ BoolValue $ asBool x && asBool y
    def "||" = Just $ fun2 (Just $ const ShapeLeaf) $ \x y ->
      return $ ValuePrim $ BoolValue $ asBool x || asBool y

    def "<" = Just $ bopDef $
              sintCmp P.CmpSlt ++ uintCmp P.CmpUlt ++
              floatCmp P.FCmpLt ++ boolCmp P.CmpLlt
    def ">" = Just $ bopDef $ flipCmps $
              sintCmp P.CmpSlt ++ uintCmp P.CmpUlt ++
              floatCmp P.FCmpLt ++ boolCmp P.CmpLlt
    def "<=" = Just $ bopDef $
               sintCmp P.CmpSle ++ uintCmp P.CmpUle ++
               floatCmp P.FCmpLe ++ boolCmp P.CmpLle
    def ">=" = Just $ bopDef $ flipCmps $
               sintCmp P.CmpSle ++ uintCmp P.CmpUle ++
               floatCmp P.FCmpLe ++ boolCmp P.CmpLle

    def s
      | Just bop <- find ((s==) . pretty) P.allBinOps =
          Just $ tbopDef $ P.doBinOp bop
      | Just unop <- find ((s==) . pretty) P.allCmpOps =
          Just $ tbopDef $ \x y -> P.BoolValue <$> P.doCmpOp unop x y
      | Just cop <- find ((s==) . pretty) P.allConvOps =
          Just $ unopDef [(getV, Just . putV, P.doConvOp cop)]
      | Just unop <- find ((s==) . pretty) P.allUnOps =
          Just $ unopDef [(getV, Just . putV, P.doUnOp unop)]

      | Just (pts, _, f) <- M.lookup s P.primFuns =
          case length pts of
            1 -> Just $ unopDef [(getV, Just . putV, f . pure)]
            _ -> Just $ fun1 Nothing $ \x -> do
              let getV' (ValuePrim v) = getV v
                  getV' _ = Nothing
              case f =<< mapM getV' =<< fromTuple x of
                Just res ->
                  return $ ValuePrim $ putV res
                _ ->
                  error $ "Cannot apply " ++ pretty s ++ " to " ++ pretty x

      | "sign_" `isPrefixOf` s =
          Just $ fun1 Nothing $ \x ->
          case x of (ValuePrim (UnsignedValue x')) ->
                      return $ ValuePrim $ SignedValue x'
                    _ -> error $ "Cannot sign: " ++ pretty x
      | "unsign_" `isPrefixOf` s =
          Just $ fun1 Nothing $ \x ->
          case x of (ValuePrim (SignedValue x')) ->
                      return $ ValuePrim $ UnsignedValue x'
                    _ -> error $ "Cannot unsign: " ++ pretty x

    def s | "map_stream" `isPrefixOf` s =
              Just $ fun2t stream

    def s | "reduce_stream" `isPrefixOf` s =
              Just $ fun3t $ \_ f arg -> stream f arg

    def "map" = Just $ fun2t $ \f xs -> do
      let ValueFun (Just shapefun) _ = f
          rowshape = shapefun $ rowShape $ valueShape xs
      Debug.Trace.trace (unwords ["mapret", pretty rowshape, "xs", pretty xs]) $
        toArray' rowshape <$> mapM (apply noLoc mempty f) (snd $ fromArray xs)

    def s | "reduce" `isPrefixOf` s = Just $ fun3t $ \f ne xs ->
      foldM (apply2 noLoc mempty f) ne $ snd $ fromArray xs

    def "scan" = Just $ fun3t $ \f ne xs -> do
      let next (out, acc) x = do
            x' <- apply2 noLoc mempty f acc x
            return (x':out, x')
      toArray' (valueShape ne) . reverse . fst <$>
        foldM next ([], ne) (snd $ fromArray xs)

    def "scatter" = Just $ fun3t $ \arr is vs ->
      case arr of
        ValueArray shape arr' ->
          return $ ValueArray shape $ foldl' update arr' $
          zip (map asInt $ snd $ fromArray is) (snd $ fromArray vs)
        _ ->
          error $ "scatter expects array, but got: " ++ pretty arr
      where update arr' (i, v) =
              if i >= 0 && i < arrayLength arr'
              then arr' // [(i, v)] else arr'

    def "hist" = Just $ fun6t $ \_ arr fun _ is vs ->
      case arr of
        ValueArray shape arr' ->
          ValueArray shape <$> foldM (update fun) arr'
          (zip (map asInt $ snd $ fromArray is) (snd $ fromArray vs))
        _ ->
          error $ "hist expects array, but got: " ++ pretty arr
      where update fun arr' (i, v) =
              if i >= 0 && i < arrayLength arr'
              then do
                v' <- apply2 noLoc mempty fun (arr' ! i) v
                return $ arr' // [(i, v')]
              else return arr'

    def "partition" = Just $ fun3t $ \k f xs -> do
      let (ShapeDim _ rowshape, xs') = fromArray xs

          next outs x = do
            i <- asInt <$> apply noLoc mempty f x
            return $ insertAt i x outs
          pack parts =
            toTuple [toArray' rowshape $ concat parts,
                     toArray' rowshape $
                     map (ValuePrim . SignedValue . Int32Value . genericLength) parts]

      pack . map reverse <$>
        foldM next (replicate (asInt k) []) xs'
      where insertAt 0 x (l:ls) = (x:l):ls
            insertAt i x (l:ls) = l:insertAt (i-1) x ls
            insertAt _ _ ls = ls

    def "cmp_threshold" = Just $ fun2t $ \_ _ ->
      return $ ValuePrim $ BoolValue True

    def "unzip" = Just $ fun1 Nothing $ \x -> do
      let ShapeDim _ (ShapeRecord fs) = Debug.Trace.trace ("unzip " ++ pretty (valueShape x)) $ valueShape x
          Just [xs_shape, ys_shape] = areTupleFields fs
          listPair (xs, ys) =
            [toArray' xs_shape xs, toArray' ys_shape ys]

      return $ toTuple $ listPair $ unzip $ map (fromPair . fromTuple) $ snd $ fromArray x
      where fromPair (Just [x,y]) = (x,y)
            fromPair l = error $ "Not a pair: " ++ pretty l

    def "zip" = Just $ fun2t $ \xs ys -> do
      let ShapeDim _ xs_rowshape = valueShape xs
          ShapeDim _ ys_rowshape = valueShape ys
      return $ toArray' (ShapeRecord (tupleFields [xs_rowshape, ys_rowshape])) $
        map toTuple $ transpose [snd $ fromArray xs, snd $ fromArray ys]

    def "concat" = Just $ fun2t $ \xs ys -> do
      let (ShapeDim _ rowshape, xs') = fromArray xs
          (_, ys') = fromArray ys
      return $ toArray' rowshape $ xs' ++ ys'

    def "transpose" = Just $ fun1 Nothing $ \xs -> do
      let (ShapeDim n (ShapeDim m shape), xs') = fromArray xs
      return $ toArray (ShapeDim m (ShapeDim n shape)) $
        map (toArray (ShapeDim n shape)) $ transpose $ map (snd . fromArray) xs'

    def "rotate" = Just $ fun2t $ \i xs -> do
      let (shape, xs') = fromArray xs
      return $
        if asInt i > 0
        then let (bef, aft) = splitAt (asInt i) xs'
             in toArray shape $ aft ++ bef
        else let (bef, aft) = splitFromEnd (-asInt i) xs'
             in toArray shape $ aft ++ bef

    def "flatten" = Just $ fun1 Nothing $ \xs -> do
      let (ShapeDim n (ShapeDim m shape), xs') = fromArray xs
      return $ toArray (ShapeDim (n*m) shape) $ concatMap (snd . fromArray) xs'

    def "unflatten" = Just $ fun3t $ \n m xs -> do
      let (ShapeDim _ innershape, xs') = fromArray xs
          rowshape = ShapeDim (asInt32 m) innershape
          shape = ShapeDim (asInt32 n) rowshape
          v = toArray shape $ map (toArray rowshape) $ chunk (asInt m) xs'
      Debug.Trace.trace ("unflatten " ++show (valueShape v)) $ return v

    def "opaque" = Just $ fun1 Nothing return

    def "trace" = Just $ fun1 Nothing $ \v -> trace v >> return v

    def "break" = Just $ fun1 Nothing $ \v -> do
      break
      return v

    def s | nameFromString s `M.member` namesToPrimTypes = Nothing

    def s = error $ "Missing intrinsic: " ++ s

    tdef s = do
      t <- nameFromString s `M.lookup` namesToPrimTypes
      return $ T.TypeAbbr Unlifted [] $ Scalar $ Prim t

    stream f arg@(ValueArray _ xs) =
      let n = ValuePrim $ SignedValue $ Int32Value $ arrayLength xs
      in apply2 noLoc mempty f n arg
    stream _ arg = error $ "Cannot stream: " ++ pretty arg


interpretExp :: Ctx -> Exp -> F ExtOp Value
interpretExp ctx e = runEvalM (ctxImports ctx) $ eval (ctxEnv ctx) e

interpretDec :: Ctx -> Dec -> F ExtOp Ctx
interpretDec ctx d = do
  env <- runEvalM (ctxImports ctx) $ evalDec (ctxEnv ctx) d
  return ctx { ctxEnv = env }

interpretImport :: Ctx -> (FilePath, Prog) -> F ExtOp Ctx
interpretImport ctx (fp, prog) = do
  env <- runEvalM (ctxImports ctx) $ foldM evalDec (ctxEnv ctx) $ progDecs prog
  return ctx { ctxImports = M.insert fp env $ ctxImports ctx }

-- | Execute the named function on the given arguments; will fail
-- horribly if these are ill-typed.
interpretFunction :: Ctx -> VName -> [F.Value] -> Either String (F ExtOp Value)
interpretFunction ctx fname vs = do
  ft <- case lookupVar (qualName fname) $ ctxEnv ctx of
          Just (TermValue (Just (T.BoundV _ t)) _) ->
            Right $ updateType (map valueType vs) t
          _ ->
            Left $ "Unknown function `" <> prettyName fname <> "`."

  vs' <- case mapM convertValue vs of
           Just vs' -> Right vs'
           Nothing -> Left "Invalid input: irregular array."

  Right $ runEvalM (ctxImports ctx) $ do
    f <- evalTermVar (ctxEnv ctx) (qualName fname) ft
    foldM (apply noLoc mempty) f vs'

  where updateType (vt:vts) (Scalar (Arrow als u _ rt)) =
          Scalar $ Arrow als u (valueStructType vt) $ updateType vts rt
        updateType _ t = t
        valueStructType = first (ConstDim . fromIntegral)

        convertValue (F.PrimValue p) = Just $ ValuePrim p
        convertValue (F.ArrayValue arr t) = mkArray t =<< mapM convertValue (elems arr)
