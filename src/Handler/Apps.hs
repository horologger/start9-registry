{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE QuasiQuotes      #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}

module Handler.Apps where

import           Startlude

import           Control.Monad.Logger
import           Data.Aeson
import qualified Data.Attoparsec.Text          as Atto
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as LBS
import           Data.Char
import           Data.Conduit
import qualified Data.Conduit.Binary           as CB
import qualified Data.HashMap.Strict           as HM
import qualified Data.Text                     as T
import qualified Data.Yaml                     as Yaml
import           Database.Persist
import qualified GHC.Show                       ( Show(..) )
import           Network.HTTP.Types
import           System.Directory
import           System.FilePath                ( (<.>)
                                                , (</>)
                                                )
import           System.Posix.Files             ( fileSize
                                                , getFileStatus
                                                )
import           Yesod.Core
import           Yesod.Persist.Core

import           Database.Queries
import           Foundation
import           Lib.Error
import           Lib.External.AppMgr
import           Lib.Registry
import           Lib.Types.AppIndex
import           Lib.Types.Emver
import           Lib.Types.FileSystem
import           Network.Wai                    ( Request(requestHeaderUserAgent) )
import           Settings
import           Util.Shared


pureLog :: Show a => a -> Handler a
pureLog = liftA2 (*>) ($logInfo . show) pure

logRet :: ToJSON a => Handler a -> Handler a
logRet = (>>= liftA2 (*>) ($logInfo . decodeUtf8 . LBS.toStrict . encode) pure)

data FileExtension = FileExtension FilePath (Maybe String)
instance Show FileExtension where
    show (FileExtension f Nothing ) = f
    show (FileExtension f (Just e)) = f <.> e

userAgentOsVersionParser :: Atto.Parser Version
userAgentOsVersionParser = do
    void $ (Atto.string "EmbassyOS" <|> Atto.string "AmbassadorOS" <|> Atto.string "MeshOS") *> Atto.char '/'
    parseVersion

getEmbassyOsVersion :: Handler (Maybe Version)
getEmbassyOsVersion = userAgentOsVersion
    where
        userAgentOsVersion =
            (hush . Atto.parseOnly userAgentOsVersionParser . decodeUtf8 <=< requestHeaderUserAgent) <$> waiRequest

getAppsManifestR :: Handler TypedContent
getAppsManifestR = do
    osVersion <- getEmbassyOsVersion
    appsDir   <- (</> "apps") . resourcesDir . appSettings <$> getYesod
    let appResourceFile = appsDir </> "apps.yaml"
    appResourceBytes <- liftIO $ BS.readFile appResourceFile
    manifest         <- case {-# SCC yaml_decode_either #-} Yaml.decodeEither' appResourceBytes of
        Left !e -> do
            $logError "COULD NOT PARSE APP INDEX! CORRECT IMMEDIATELY!"
            $logError (show e)
            sendResponseStatus status500 ("Internal Server Error" :: Text)
        Right !a -> pure a
    let pruned = case osVersion of
            Nothing -> manifest
            Just av -> AppManifest . HM.mapMaybe (filterOsRecommended av) . unAppManifest $ manifest
    withServiceTimestamps <- fmap AppManifest . HM.traverseWithKey (addFileTimestamp' appsDir) . unAppManifest $ pruned
    pure . TypedContent "application/x-yaml" . toContent . Yaml.encode $! withServiceTimestamps
    where
        addFileTimestamp' :: (MonadHandler m, MonadIO m) => FilePath -> AppIdentifier -> StoreApp -> m StoreApp
        addFileTimestamp' dir appId service = do
            let ext = (Extension (toS appId) :: Extension "s9pk")
            mostRecentVersion <- liftIO $ getMostRecentAppVersion dir ext
            (v, _)            <- case mostRecentVersion of
                Nothing -> notFound
                Just a  -> pure $ unRegisteredAppVersion a
            liftIO (addFileTimestamp dir ext service v) >>= \case
                Nothing               -> notFound
                Just appWithTimestamp -> pure appWithTimestamp

getSysR :: Extension "" -> Handler TypedContent
getSysR e = do
    sysResourceDir <- (</> "sys") . resourcesDir . appSettings <$> getYesod
    getApp sysResourceDir e

getAppManifestR :: AppIdentifier -> Handler TypedContent
getAppManifestR appId = do
    (appsDir, appMgrDir) <- getsYesod $ ((</> "apps") . resourcesDir &&& staticBinDir) . appSettings
    av                   <- getVersionFromQuery appsDir appExt >>= \case
        Nothing -> sendResponseStatus status400 ("Specified App Version Not Found" :: Text)
        Just v  -> pure v
    let appDir = (<> "/") . (</> show av) . (</> toS appId) $ appsDir
    manifest <- handleS9ErrT $ getManifest appMgrDir appDir appExt
    pure $ TypedContent "application/json" (toContent manifest)
    where appExt = Extension (toS appId) :: Extension "s9pk"

getAppConfigR :: AppIdentifier -> Handler TypedContent
getAppConfigR appId = do
    appSettings <- appSettings <$> getYesod
    let appsDir   = (</> "apps") . resourcesDir $ appSettings
    let appMgrDir = staticBinDir appSettings
    av <- getVersionFromQuery appsDir appExt >>= \case
        Nothing -> sendResponseStatus status400 ("Specified App Version Not Found" :: Text)
        Just v  -> pure v
    let appDir = (<> "/") . (</> show av) . (</> toS appId) $ appsDir
    config <- handleS9ErrT $ getConfig appMgrDir appDir appExt
    pure $ TypedContent "application/json" (toContent config)
    where appExt = Extension (toS appId) :: Extension "s9pk"

getAppR :: Extension "s9pk" -> Handler TypedContent
getAppR e = do
    appResourceDir <- (</> "apps") . resourcesDir . appSettings <$> getYesod
    getApp appResourceDir e

getApp :: KnownSymbol a => FilePath -> Extension a -> Handler TypedContent
getApp rootDir ext@(Extension appId) = do
    specString <- T.filter (not . isSpace) . fromMaybe "*" <$> lookupGetParam "spec"
    spec       <- case readMaybe specString of
        Nothing -> sendResponseStatus status400 ("Invalid App Version Specification" :: Text)
        Just t  -> pure t
    appVersions <- liftIO $ getAvailableAppVersions rootDir ext
    putStrLn $ "valid appversion for " <> (show ext :: String) <> ": " <> show appVersions
    let satisfactory = filter ((<|| spec) . fst . unRegisteredAppVersion) appVersions
    let best = fst . getMaxVersion <$> foldMap (Just . MaxVersion . (, fst . unRegisteredAppVersion)) satisfactory
    case best of
        Nothing -> notFound
        Just (RegisteredAppVersion (appVersion, filePath)) -> do
            existence <- liftIO $ doesFileExist filePath >>= \case
                True  -> pure Existent
                False -> pure NonExistent
            determineEvent existence (extension ext) filePath appVersion
    where
        determineEvent :: FileExistence -> String -> FilePath -> Version -> HandlerFor RegistryCtx TypedContent
        -- for app files
        determineEvent Existent "s9pk" fp av = do
            _ <- recordMetrics appId rootDir av
            chunkIt fp
        -- for png, system, etc
        determineEvent Existent    _ fp _ = chunkIt fp
        determineEvent NonExistent _ _  _ = notFound

chunkIt :: FilePath -> HandlerFor RegistryCtx TypedContent
chunkIt fp = do
    sz <- liftIO $ fileSize <$> getFileStatus fp
    addHeader "Content-Length" (show sz)
    respondSource typeOctet $ CB.sourceFile fp .| awaitForever sendChunkBS

recordMetrics :: String -> FilePath -> Version -> HandlerFor RegistryCtx ()
recordMetrics appId rootDir appVersion = do
    let appId' = T.pack appId
    manifest                <- liftIO $ getAppManifest rootDir
    (storeApp, versionInfo) <- case HM.lookup appId' $ unAppManifest manifest of
        Nothing -> sendResponseStatus status400 ("App not present in manifest" :: Text)
        Just sa -> do
            -- look up at specfic version
            vi <- case find ((appVersion ==) . versionInfoVersion) (storeAppVersionInfo sa) of
                Nothing -> sendResponseStatus status400 ("App version not present in manifest" :: Text)
                Just x  -> pure x
            pure (sa, vi)
    -- lazy load app at requested version if it does not yet exist to automatically transfer from using apps.yaml
    runDB $ do
        sa                   <- fetchApp appId'
        (appKey, versionKey) <- case sa of
            Nothing -> do
                appKey'     <- createApp appId' storeApp >>= errOnNothing status500 "duplicate app created"
                versionKey' <- createAppVersion appKey' versionInfo
                    >>= errOnNothing status500 "duplicate app version created"
                pure (appKey', versionKey')
            Just a -> do
                let appKey' = entityKey a
                existingVersion <- fetchAppVersion appVersion appKey'
                case existingVersion of
                    Nothing -> do
                        appVersion' <- createAppVersion appKey' versionInfo
                            >>= errOnNothing status500 "duplicate app version created"
                        pure (appKey', appVersion')
                    Just v -> pure (appKey', entityKey v)
        createMetric appKey versionKey
