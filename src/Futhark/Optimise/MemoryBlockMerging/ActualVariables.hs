{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Find the actual variables that need updating when a variable attribute
-- needs updating.  This is different than variable aliasing: Variable aliasing
-- is a theoretical concept, while this module has the practical purpose of
-- finding any extra variables that also need a change when a variable has a
-- change of memory block.
module Futhark.Optimise.MemoryBlockMerging.ActualVariables
  ( findActualVariables
  ) where

import qualified Data.Set as S
import qualified Data.Map.Strict as M
import qualified Data.List as L
import Data.Maybe (mapMaybe, catMaybes)
import Control.Monad
import Control.Monad.RWS

import Futhark.Representation.AST
import Futhark.Representation.ExplicitMemory (ExplicitMemorish)
import qualified Futhark.Representation.ExplicitMemory as ExpMem
import Futhark.Representation.Kernels.Kernel

import Futhark.Optimise.MemoryBlockMerging.Miscellaneous
import Futhark.Optimise.MemoryBlockMerging.Types


getFullMap :: [M.Map VName Names] -> M.Map VName Names
getFullMap = M.unionsWith S.union

type Context = VarMemMappings MemorySrc

newtype FindM lore a = FindM { unFindM :: RWS Context [ActualVariables] () a }
  deriving (Monad, Functor, Applicative,
            MonadReader Context,
            MonadWriter [ActualVariables])

type LoreConstraints lore = (ExplicitMemorish lore,
                             FullWalk lore)

coerce :: (ExplicitMemorish flore, ExplicitMemorish tlore) =>
          FindM flore a -> FindM tlore a
coerce = FindM . unFindM

recordActuals :: VName -> Names -> FindM lore ()
recordActuals stmt_var more_actuals = tell [M.singleton stmt_var more_actuals]

findActualVariables :: LoreConstraints lore =>
                       VarMemMappings MemorySrc
                    -> FunDef lore -> ActualVariables
findActualVariables var_mem_mappings fundef =
  let context = var_mem_mappings
      m = unFindM $ lookInBody $ funDefBody fundef
      actual_variables = getFullMap $ snd $ execRWS m context ()
  in actual_variables

lookInBody :: LoreConstraints lore =>
              Body lore -> FindM lore ()
lookInBody (Body _ bnds _res) =
  mapM_ lookInStm bnds

lookInKernelBody :: LoreConstraints lore =>
                    KernelBody lore -> FindM lore ()
lookInKernelBody (KernelBody _ bnds _res) =
  mapM_ lookInStm bnds

lookInStm :: LoreConstraints lore =>
             Stm lore -> FindM lore ()
lookInStm (Let (Pattern patctxelems patvalelems) _ e) = do
  forM_ patvalelems $ \(PatElem var bindage _) ->
    case bindage of
      BindInPlace _ orig _ -> do
        -- Record that when coalescing an in-place update statement, also look
        -- at the original array.
        let actuals = S.fromList [var, orig]
        recordActuals var actuals
      _ -> return ()

  -- Special handling of loops, ifs, etc.
  case e of
    DoLoop _mergectxparams mergevalparams _loopform body ->
      forM_ patvalelems $ \(PatElem var _ membound) -> do
        case membound of
          ExpMem.ArrayMem _ _ _ mem _ -> do
            -- If mem is existential, we need to find the return memory that it
            -- refers to.  We cannot just look at its memory aliases, since it
            -- likely aliases both the initial memory and the final memory.

            let zipped = zip patctxelems (bodyResult body)
                mem_search = case L.find ((== mem) . patElemName . fst) zipped of
                  Just (_, Var res_mem) -> res_mem
                  _ -> mem
            let body_vars0 = mapMaybe (fromVar . snd) mergevalparams
                body_vars1 = map (paramName . fst) mergevalparams
                body_vars2 = concatMap (map patElemName
                                        . patternValueElements . stmPattern)
                             $ bodyStms body
                body_vars = body_vars0 ++ body_vars1 ++ body_vars2
            -- Find the ones using the same memory as the result of the loop
            -- expression.
            body_vars' <- filterM (\v -> do
                                      m <- M.lookup v <$> ask
                                      return $ Just mem_search == (memSrcName <$> m)
                                  ) body_vars
            -- Not only the result variable needs to change its memory block in case
            -- of a future coalescing with it; also the variables extracted above.
            -- FIXME: This is probably an okay way to do it?  What if the memory is
            -- used, but with a different index function?  Can that happen?
            let actuals = var : body_vars'
            forM_ actuals $ \a -> recordActuals a (S.fromList actuals)
            -- Some of these can be changed later on to have an actual variable
            -- set of S.empty, e.g. if one of the variables using the memory is
            -- a rearrange operation.  This is fine, and will occur in the walk
            -- later on.

            -- If you extend this loop handling, make sure not to target existential
            -- memory blocks.  We want those to stay.
          _ -> return ()

        -- It seems wrong to change the memory of merge variables, so we disable
        -- it.  If we were to accept it, we would need to record what other
        -- variables to change as well.  Seems hard.
        recordActuals var S.empty

    If _se body_then body_else _types ->
      -- We don't want to coalesce the existiential memory block of the if.
      -- However, if a branch result has a memory block that is firstly used
      -- inside the branch, it is okay to coalesce that in a future statement.
      forM_ (zip3 patvalelems (bodyResult body_then) (bodyResult body_else))
        $ \(PatElem var _ membound, res_then, res_else) ->
        case membound of
          ExpMem.ArrayMem _ _ _ mem _ ->
            if mem `L.elem` map patElemName patctxelems
              then do
              -- If the memory block is existential, we say that the If result
              -- refers to all results in the If.
              let actuals = S.fromList (var : catMaybes [fromVar res_then, fromVar res_else])
              recordActuals var actuals

              else do
              -- If the memory block is not existential, we need to find all the
              -- variables in any sub-bodies using the same memory block (like
              -- with loops).
              let varFromStm stm = map patElemName (patternValueElements $ stmPattern stm)
                                 ++ foldExp folder [] (stmExp stm)
                  folder = identityFolder { foldOnBody = \vs fbody -> return (vs ++ concatMap varFromStm (bodyStms fbody)) }
                  body_vars = foldExp folder [] e -- Get all statements in the
                                                  -- body *and* any sub-bodies,
                                                  -- etc.
              -- Find the ones using the same memory as the result of the loop
              -- expression.
              body_vars' <- filterM (\v -> do
                                        m <- M.lookup v <$> ask
                                        return $ Just mem == (memSrcName <$> m)
                                    ) body_vars
              -- Not only the result variable needs to change its memory block in case
              -- of a future coalescing with it; also the variables extracted above.
              -- FIXME: This is probably an okay way to do it?  What if the memory is
              -- used, but with a different index function?  Can that happen?
              let actuals = S.fromList (var : body_vars')
              recordActuals var actuals

          _ -> return ()

    BasicOp (Index _ orig _) -> do
      let ielem = head patvalelems -- Should be okay.
          var = patElemName ielem
      case patElemAttr ielem of
        ExpMem.ArrayMem{} -> do
          -- Disable merging for index expressions that return arrays.  Maybe
          -- too restrictive.
          recordActuals var S.empty
          -- Make sure the source also updates the memory of the index when
          -- updated.
          recordActuals orig $ S.fromList [orig, var]
        _ -> return ()

    -- Support reusing the memory of reshape operations by recording the origin
    -- array that is being reshaped.  Unexpected behaviour if the source is also
    -- a reshape or similar.
    BasicOp (Reshape _ _ orig) ->
      forM_ (map patElemName patvalelems) $ \var -> do
        -- let actuals = S.fromList [var, orig]
        recordActuals var S.empty -- actuals -- FIXME
        recordActuals orig $ S.fromList [orig, var]
        -- FIXME: The problem is that a slice is relative to the shape of the
        -- reshaped array, and not the original array.  Disabled for now.

    -- For the other aliasing operations, disable their use for now.  If the
    -- source has a change of memory block, make sure to change this as well.
    BasicOp (Rearrange _ _ orig) ->
      forM_ (map patElemName patvalelems) $ \var -> do
        recordActuals var S.empty
        recordActuals orig $ S.fromList [orig, var]

    BasicOp (Split _ _ _ orig) ->
      forM_ (map patElemName patvalelems) $ \var -> do
        recordActuals var S.empty
        recordActuals orig $ S.fromList [orig, var]

    BasicOp (Opaque (Var orig)) ->
      forM_ (map patElemName patvalelems) $ \var -> do
        recordActuals var S.empty
        recordActuals orig $ S.fromList [orig, var]

    _ -> return ()

  fullWalkExpM walker walker_kernel e
  where walker = identityWalker
          { walkOnBody = lookInBody }
        walker_kernel = identityKernelWalker
          { walkOnKernelBody = coerce . lookInBody
          , walkOnKernelKernelBody = coerce . lookInKernelBody
          }