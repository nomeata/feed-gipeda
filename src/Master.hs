{-| Handles all the config file watching and repository updating.
    Executes an IO action when a repository was (re-)fetched, also supplying
    commits, for which there was no results file found in site/out/results.

    Repositories are re-fetched at a fixed rate. Existing clones are detected
    and reused, so that restarting the daemon will not do unnecessary work.
-}

module Master
  ( Paths (..)
  , OperationMode (..)
  , checkForNewCommits
  ) where


import qualified Config
import           Control.Concurrent         (forkIO, threadDelay)
import           Control.Concurrent.MVar    (MVar, newEmptyMVar, putMVar,
                                             readMVar)
import           Control.Monad              (forM_, forever)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Maybe                 (fromMaybe, listToMaybe)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.Time                  (NominalDiffTime)
import qualified Data.Time                  as Time
import           GitShell                   (SHA)
import qualified GitShell
import qualified Master.File                as File
import qualified Master.Finalize            as Finalize
import           Master.RepoDiff            (RepoDiff)
import qualified Master.RepoDiff            as RepoDiff
import           Reactive.Banana            ((<@), (<@>))
import qualified Reactive.Banana            as Banana
import qualified Reactive.Banana.Frameworks as Banana
import           Repo                       (Repo)
import qualified Repo
import           System.Directory           (getCurrentDirectory)
import           System.FilePath            (equalFilePath)
import qualified System.FSNotify            as FS


type NewCommitAction
  = (String -> IO ()) -> Repo -> SHA -> IO ()


notifyOnNewCommitsInBacklog :: NewCommitAction -> (Repo, Set SHA) -> IO ()
notifyOnNewCommitsInBacklog onNewCommit (repo, backlog) =
  forM_ backlog $ \commit ->
    onNewCommit (File.writeBenchmarkCSV repo commit) repo commit


finalizeRepos :: Paths -> Set Repo -> Set Repo -> IO ()
finalizeRepos paths activeRepos repos = forM_ repos $ \repo -> do
  Finalize.regenerateAndDeploy (gipeda paths) (remoteDir paths) activeRepos repo
  File.writeBacklog repo


readConfigFileRepos :: FS.Event -> IO (Maybe (Set Repo))
readConfigFileRepos evt =
  case evt of
    FS.Removed _ _ -> return (Just Set.empty)
    _ ->
      Config.decodeFile (FS.eventPath evt) >>= either
        (\err -> putStrLn err >> return Nothing)
        (return . Just . Config.repos)


accumDiff
  :: Banana.MonadMoment moment
  => Banana.Event (Set Repo)
  -> moment (Banana.Event RepoDiff)
accumDiff repos =
  fst <$> Banana.mapAccum Set.empty ((\new old -> (RepoDiff.compute old new, new)) <$> repos)


dedupCommits
  :: Banana.MonadMoment moment
  => Banana.Event (Repo, Set SHA)
  -> moment (Banana.Event (Repo, Set SHA))
dedupCommits commits =
  fst <$> Banana.mapAccum Map.empty (filterDuplicates <$> commits)
    where
      filterDuplicates
        :: (Repo, Set SHA)
        -> Map Repo (Set SHA)
        -> ((Repo, Set SHA), Map Repo (Set SHA))
      filterDuplicates (repo, commits) inProgress =
        let
          nonDuplicates =
            Set.difference commits (fromMaybe Set.empty (Map.lookup repo inProgress))
        in
          ((repo, nonDuplicates), Map.insert repo commits inProgress)


periodically :: NominalDiffTime -> Banana.MomentIO (Banana.Event ())
periodically dt = do
  (event, fire) <- Banana.newEvent
  liftIO $ forkIO $ forever $ do
    begin <- Time.getCurrentTime
    fire ()
    end <- Time.getCurrentTime
    let elapsed = Time.diffUTCTime end begin
    threadDelay (ceiling ((dt - elapsed) * 1000000))
  return event


singleShot :: MVar () -> Banana.MomentIO (Banana.Event ())
singleShot mvar = do
  (event, fire) <- Banana.newEvent
  liftIO $ forkIO $ readMVar mvar >>= fire
  return event


repoOfFileEvent
  :: FilePath
  -> Banana.Behavior (Set Repo)
  -> Banana.Event FS.Event
  -> Banana.MomentIO (Banana.Event Repo)
repoOfFileEvent cwd activeRepos fileEvents =
  Banana.filterJust <$> Banana.mapEventIO
    id
    (File.repoOfPath cwd <$> activeRepos <@> (FS.eventPath <$> fileEvents))


data OperationMode
  = OneShot
  | PeriodicRefresh NominalDiffTime
  deriving (Show, Eq)


data Paths
  = Paths
  { configFile :: FilePath
  , remoteDir  :: Maybe String
  , gipeda     :: FilePath
  }


checkForNewCommits
  :: Paths
  -> OperationMode
  -> NewCommitAction
  -> IO ()
checkForNewCommits paths mode onNewCommit = FS.withManager $ \mgr -> do
  cwd <- getCurrentDirectory
  exit <- newEmptyMVar
  start <- newEmptyMVar

  let
    watchFile :: FilePath -> Banana.MomentIO (Banana.Event FS.Event)
    watchFile path = do
      (event, fire) <- Banana.newEvent
      liftIO (FS.watchDir mgr path (equalFilePath path . FS.eventPath) fire)
      return event

    watchTree :: FilePath -> (FilePath -> Bool) -> Banana.MomentIO (Banana.Event FS.Event)
    watchTree path predicate = do
      (event, fire) <- Banana.newEvent
      liftIO (FS.watchTree mgr path (predicate . FS.eventPath) fire)
      return event

    networkDescription :: Banana.MomentIO ()
    networkDescription = do
      -- Source: Initial tick to read in the file
      config <- (FS.Added (configFile paths) undefined <$) <$> singleShot start

      -- Source: Events resulting from watching the config file
      configFileChanges <-
        case mode of
          OneShot -> return config
          PeriodicRefresh _ -> Banana.unionWith const config <$> watchFile (configFile paths)
      activeRepos <- Banana.filterJust <$> Banana.mapEventIO readConfigFileRepos configFileChanges
      activeReposB <- Banana.stepper Set.empty activeRepos
      diffsWithoutRefresh <- accumDiff activeRepos
      -- Source: When in PeriodicRefresh mode, occasionally mark all repos dirty
      diffs <-
        case mode of
          OneShot -> return diffsWithoutRefresh
          PeriodicRefresh dt -> do
            ticks <- periodically dt
            return (RepoDiff.compute Set.empty <$> activeReposB <@ ticks)

      -- Fetch every added ('dirty') repository, delay until fetch is complete
      -- TODO: parallelize and/or get rid of mapM_ somehow
      fetchedRepos <-
        Banana.mapEventIO
          (\added -> mapM_ GitShell.sync added >> return added)
          (RepoDiff.added <$> diffs)

      -- Source: Changed benchmark CSV files
      benchmarks <- watchTree cwd (File.isBenchmarkCSV cwd)
      benchmarkedRepos <- repoOfFileEvent cwd activeReposB benchmarks

      -- Sink: produce the appropriate backlog and deploy
      let reposToFinish = Banana.unionWith Set.union fetchedRepos (Set.singleton <$> benchmarkedRepos)
      Banana.reactimate (finalizeRepos paths <$> activeReposB <@> reposToFinish)

      -- Source: Backlog changes
      backlogs <- watchTree cwd (File.isBacklog cwd)
      backlogRepos <- repoOfFileEvent cwd activeReposB backlogs

      -- Sink: Backlog changes kick off workers, resp. the new commit action
      backlogCommits <- Banana.mapEventIO (\repo -> (,) repo <$> File.readBacklog repo) backlogRepos
      dedupedCommits <- dedupCommits backlogCommits
      Banana.reactimate (notifyOnNewCommitsInBacklog onNewCommit <$> dedupedCommits)

  network <- Banana.compile networkDescription
  Banana.actuate network
  putMVar start ()
  readMVar exit