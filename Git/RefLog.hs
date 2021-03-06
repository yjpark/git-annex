{- git reflog interface
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Git.RefLog where

import Common
import Git
import Git.Command
import Git.Sha

{- Gets the reflog for a given branch. -}
get :: Branch -> Repo -> IO [Sha]
get b = mapMaybe extractSha . lines <$$> pipeReadStrict
	[ Param "log"
	, Param "-g"
	, Param "--format=%H"
	, Param (fromRef b)
	]
