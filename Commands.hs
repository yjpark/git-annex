{- git-annex command line -}

module Commands (parseCmd) where

import System.Console.GetOpt
import Control.Monad.State (liftIO)
import System.Posix.Files
import System.Directory
import System.Path
import Data.String.Utils
import List
import IO

import qualified GitRepo as Git
import qualified Annex
import Utility
import Locations
import qualified Backend
import BackendList
import UUID
import LocationLog
import Types
import Core
import qualified Remotes
import qualified BackendTypes

data CmdWants = FilesInGit | FilesNotInGit | RepoName | SingleString
data Command = Command {
	cmdname :: String,
	cmdaction :: (String -> Annex ()),
	cmdwants :: CmdWants
}

cmds :: [Command]
cmds =  [
	  (Command "add"	addCmd		FilesNotInGit)
	, (Command "get"	getCmd		FilesInGit)
	, (Command "drop"	dropCmd		FilesInGit)
	, (Command "push"	pushCmd		RepoName)
	, (Command "pull"	pullCmd		RepoName)
	, (Command "unannex"	unannexCmd	FilesInGit)
	, (Command "describe"	describeCmd	SingleString)
	]

options = [
	    Option ['f'] ["force"] (NoArg Force) "allow actions that may loose annexed data"
	  , Option ['N'] ["no-commit"] (NoArg NoCommit) "do not stage or commit changes"
	  ]

{- Finds the type of parameters a command wants, from among the passed
 - parameter list. -}
findWanted :: CmdWants -> [String] -> Git.Repo -> IO [String]
findWanted FilesNotInGit params repo = do
	files <- mapM (Git.notInRepo repo) params
	return $ foldl (++) [] files
findWanted FilesInGit params repo = do
	files <- mapM (Git.inRepo repo) params
	return $ foldl (++) [] files
findWanted SingleString params _ = do
	return $ [unwords params]
findWanted RepoName params _ = do
	return $ params

{- Parses command line and returns a list of flags and a list of
 - actions to be run in the Annex monad. -}
parseCmd :: [String] -> AnnexState -> IO ([Flag], [Annex ()])
parseCmd argv state = do
	(flags, params) <- getopt
	case (length params) of
		0 -> error header
		_ -> case (lookupCmd (params !! 0)) of
			[] -> error header
			[Command _ action want] -> do
				f <- findWanted want (drop 1 params)
					(BackendTypes.repo state)
				return (flags, map action f)
	where
		getopt = case getOpt Permute options argv of
			(flags, params, []) -> return (flags, params)
			(_, _, errs) -> ioError (userError (concat errs ++ usageInfo header options))
		lookupCmd cmd = filter (\c -> cmd  == cmdname c) cmds
		header = "Usage: git-annex [" ++ 
			(join "|" $ map cmdname cmds) ++ "] ..."

{- Annexes a file, storing it in a backend, and then moving it into
 - the annex directory and setting up the symlink pointing to its content. -}
addCmd :: FilePath -> Annex ()
addCmd file = inBackend file err $ do
	liftIO $ checkLegal file
	g <- Annex.gitRepo
	link <- liftIO $ calcGitLink file g
	stored <- Backend.storeFileKey file
	case (stored) of
		Nothing -> error $ "no backend could store: " ++ file
		Just (key, backend) -> do
			logStatus key ValuePresent
			setup g key link
	where
		err = error $ "already annexed " ++ file
		checkLegal file = do
			s <- getSymbolicLinkStatus file
			if ((isSymbolicLink s) || (not $ isRegularFile s))
				then error $ "not a regular file: " ++ file
				else return ()
		calcGitLink file g = do
			cwd <- getCurrentDirectory
			let absfile = case (absNormPath cwd file) of
				Just f -> f
				Nothing -> error $ "unable to normalize " ++ file
			return $ relPathDirToDir (parentDir absfile) (Git.workTree g)
		setup g key link = do
			let dest = annexLocation g key
			let reldest = annexLocationRelative g key
			liftIO $ createDirectoryIfMissing True (parentDir dest)
			liftIO $ renameFile file dest
			liftIO $ createSymbolicLink (link ++ reldest) file
			gitAdd file $ Just $ "git-annex annexed " ++ file

{- Inverse of addCmd. -}
unannexCmd :: FilePath -> Annex ()
unannexCmd file = notinBackend file err $ \(key, backend) -> do
	Backend.removeKey backend key
	logStatus key ValueMissing
	g <- Annex.gitRepo
	let src = annexLocation g key
	liftIO $ moveout g src
	where
		err = error $ "not annexed " ++ file
		moveout g src = do
			removeFile file
			Git.run g ["rm", file]
			Git.run g ["commit", "-m",
				("git-annex unannexed " ++ file), file]
			-- git rm deletes empty directories;
			-- put them back
			createDirectoryIfMissing True (parentDir file)
			renameFile src file
			return ()

{- Gets an annexed file from one of the backends. -}
getCmd :: FilePath -> Annex ()
getCmd file = notinBackend file err $ \(key, backend) -> do
	inannex <- inAnnex key
	if (inannex)
		then return ()
		else do
			g <- Annex.gitRepo
			let dest = annexLocation g key
			liftIO $ createDirectoryIfMissing True (parentDir dest)
			success <- Backend.retrieveKeyFile backend key dest
			if (success)
				then do
					logStatus key ValuePresent
					return ()
				else error $ "failed to get " ++ file
	where
		err = error $ "not annexed " ++ file

{- Indicates a file's content is not wanted anymore, and should be removed
 - if it's safe to do so. -}
dropCmd :: FilePath -> Annex ()
dropCmd file = notinBackend file err $ \(key, backend) -> do
	force <- Annex.flagIsSet Force
	if (not force)
		then requireEnoughCopies key
		else return ()
	success <- Backend.removeKey backend key
	if (success)
		then do
			logStatus key ValueMissing
			inannex <- inAnnex key
			if (inannex)
				then do
					g <- Annex.gitRepo
					let loc = annexLocation g key
					liftIO $ removeFile loc
					return ()
				else return ()
		else error $ "backend refused to drop " ++ file
	where
		err = error $ "not annexed " ++ file

{- Pushes all files to a remote repository. -}
pushCmd :: String -> Annex ()
pushCmd reponame = do error "not implemented" -- TODO

{- Pulls all files from a remote repository. -}
pullCmd :: String -> Annex ()
pullCmd reponame = do error "not implemented" -- TODO

{- Stores description for the repository. -}
describeCmd :: String -> Annex ()
describeCmd description = do
	g <- Annex.gitRepo
	u <- getUUID g
	describeUUID u description
	log <- uuidLog
	gitAdd log Nothing -- all logs are committed at end
	liftIO $ putStrLn "description set"

{- Updates the LocationLog when a key's presence changes. -}
logStatus :: Key -> LogStatus -> Annex ()
logStatus key status = do
	g <- Annex.gitRepo
	u <- getUUID g
	f <- liftIO $ logChange g key u status
	gitAdd f Nothing -- all logs are committed at end

inBackend file yes no = do
	r <- liftIO $ Backend.lookupFile file
	case (r) of
		Just v -> yes v
		Nothing -> no
notinBackend file yes no = inBackend file no yes

{- Checks remotes to verify that enough copies of a key exist to allow
 - for a key to be safely removed (with no data loss), and fails with an
 - error if not. -}
requireEnoughCopies :: Key -> Annex ()
requireEnoughCopies key = do
	g <- Annex.gitRepo
	let numcopies = read $ Git.configGet g config "1"
	remotes <- Remotes.withKey key
	if (numcopies > length remotes)
		then error $ "I only know about " ++ (show $ length remotes) ++ 
			" out of " ++ (show numcopies) ++ 
			" necessary copies of: " ++ (keyFile key) ++
			unsafe
		else findcopies numcopies remotes []
	where
		findcopies 0 _ _ = return () -- success, enough copies found
		findcopies _ [] bad = die bad
		findcopies n (r:rs) bad = do
			result <- liftIO $ try $ haskey r
			case (result) of
				Right True	-> findcopies (n-1) rs bad
				Right False	-> findcopies n rs bad
				Left _		-> findcopies n rs (r:bad)
		haskey r = do
			-- To check if a remote has a key, construct a new
			-- Annex monad and query its backend.
			a <- Annex.new r
			(result, _) <- Annex.run a (Backend.hasKey key)
			return result
		die bad =
			error $ "I failed to find enough other copies of: " ++
				(keyFile key) ++
				(if (0 /= length bad) then listbad bad else "")
				++ unsafe
		listbad bad = "\nI was unable to access these remotes: " ++
				(Remotes.list bad) 
		unsafe = "\n" ++
			"  -- According to the " ++ config ++
			" setting, it is not safe to remove it!\n" ++
			"     (Use --force to override.)"

		config = "annex.numcopies"
