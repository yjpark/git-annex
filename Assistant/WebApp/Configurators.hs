{- git-annex assistant webapp configurators
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses, TemplateHaskell, OverloadedStrings, RankNTypes, CPP #-}

module Assistant.WebApp.Configurators where

import Assistant.WebApp.Common
import Assistant.WebApp.RepoList
import Assistant.WebApp.Configurators.Local
#ifdef WITH_XMPP
import Assistant.XMPP.Client
#endif

{- The main configuration screen. -}
getConfigurationR :: Handler RepHtml
getConfigurationR = ifM (inFirstRun)
	( getFirstRepositoryR
	, page "Configuration" (Just Configuration) $ do
#ifdef WITH_XMPP
		xmppconfigured <- lift $ liftAnnex $ isJust <$> getXMPPCreds
#else
		let xmppconfigured = False
#endif
		$(widgetFile "configurators/main")
	)

getAddRepositoryR :: Handler RepHtml
getAddRepositoryR = page "Add Repository" (Just Configuration) $ do
	let repolist = repoListDisplay mainRepoSelector
	$(widgetFile "configurators/repositories")

makeMiscRepositories :: Widget
makeMiscRepositories = $(widgetFile "configurators/repositories/misc")

makeCloudRepositories :: Bool -> Widget
makeCloudRepositories onlyTransfer = $(widgetFile "configurators/repositories/cloud")
