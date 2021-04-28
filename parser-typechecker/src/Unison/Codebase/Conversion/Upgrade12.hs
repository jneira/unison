{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{-# LANGUAGE ViewPatterns #-}
module Unison.Codebase.Conversion.Upgrade12 where

import Control.Exception.Safe (MonadCatch)
import Control.Lens (Lens', (&), (.~), (^.))
import qualified Control.Lens as Lens
import Control.Monad.Except (ExceptT (ExceptT), runExceptT)
import qualified Control.Monad.Reader as Reader
import Control.Monad.State (StateT (StateT, runStateT))
import qualified Control.Monad.State as State
import Control.Monad.Trans (lift)
import qualified U.Codebase.Sync as Sync
import Unison.Codebase (CodebasePath)
import qualified Unison.Codebase as Codebase
import Unison.Codebase.Branch (Branch (Branch))
import qualified Unison.Codebase.Causal as Causal
import qualified Unison.Codebase.Conversion.Sync12 as Sync12
import qualified Unison.Codebase.FileCodebase as FC
import qualified Unison.Codebase.Init as Codebase
import qualified Unison.Codebase.SqliteCodebase as SC
import qualified Unison.PrettyTerminal as CT
import UnliftIO (MonadIO, liftIO)
import qualified Data.Map as Map

upgradeCodebase :: forall m. (MonadIO m, MonadCatch m) => CodebasePath -> m ()
upgradeCodebase root = do
  either (liftIO . CT.putPrettyLn) pure =<< runExceptT do
    srcCB <- ExceptT $ Codebase.openCodebase FC.init root
    destCB <- ExceptT $ Codebase.createCodebase SC.init root
    destDB <- SC.unsafeGetConnection root
    let env = Sync12.Env srcCB destCB destDB
    let initialState = (Sync12.emptyDoneCount, Sync12.emptyErrorCount, Sync12.emptyStatus)
    rootEntity <-
      lift (Codebase.getRootBranch srcCB) >>= \case
        Left e -> error $ "Error loading source codebase root branch: " ++ show e
        Right (Branch c) -> pure $ Sync12.C (Causal.currentHash c) (pure c)
    (_, _, s) <- flip Reader.runReaderT env . flip State.execStateT initialState $ do
      sync <- Sync12.sync12 (lift . lift . lift)
      Sync.sync @_ @(Sync12.Entity _)
        (Sync.transformSync (lensStateT Lens._3) sync)
        Sync12.simpleProgress
        [rootEntity]
    lift $ Codebase.putRootBranch destCB =<< fmap Branch case rootEntity of
      Sync12.C h mc -> case Map.lookup h (Sync12._branchStatus s) of
        Just Sync12.BranchOk -> mc
        Just (Sync12.BranchReplaced _h' c') -> pure c'
        Nothing -> error "We didn't sync the root?"
      _ -> error "The root wasn't a causal?"
    pure ()

  where
    lensStateT :: forall m s1 s2 a. Monad m => Lens' s2 s1 -> StateT s1 m a -> StateT s2 m a
    lensStateT l m = StateT \s2 -> do
      (a, s1') <- runStateT m (s2 ^. l)
      pure (a, s2 & l .~ s1')
