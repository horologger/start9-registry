{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- | Settings are centralized, as much as possible, into this file. This
-- includes database connection settings, static file locations, etc.
-- In addition, you can configure a number of different aspects of Yesod
-- by overriding methods in the Yesod typeclass. That instance is
-- declared in the Foundation.hs file.
module Settings where

import           Paths_start9_registry          ( version )
import           Startlude                      ( ($)
                                                , (.)
                                                , (<$>)
                                                , Applicative(liftA2)
                                                , Bool(..)
                                                , ByteString
                                                , ConvertText(toS)
                                                , FilePath
                                                , IsString(fromString)
                                                , Monad(return)
                                                , Monoid(mempty)
                                                , Text
                                                , Word16
                                                , either
                                                , id
                                                , panic
                                                )

import qualified Control.Exception             as Exception
import           Data.Aeson                     ( (.!=)
                                                , (.:)
                                                , (.:?)
                                                , FromJSON(parseJSON)
                                                , Result(Error, Success)
                                                , Value(String)
                                                , fromJSON
                                                , withObject
                                                )
import           Data.Aeson.Types               ( parseMaybe )
import           Data.FileEmbed                 ( embedFile )
import           Data.Maybe                     ( fromJust )
import           Data.Version                   ( showVersion )
import           Data.Yaml                      ( decodeEither' )
import           Data.Yaml.Config               ( applyEnvValue )
import           Database.Persist.Postgresql    ( PostgresConf )
import           Network.Wai.Handler.Warp       ( HostPreference )
import           System.FilePath                ( (</>)
                                                , takeDirectory
                                                )
import           Yesod.Default.Config2          ( configSettingsYml )

import           Control.Monad.Reader.Has       ( Has(extract, update) )
import           Lib.PkgRepository              ( EosRepo(EosRepo, eosRepoFileRoot)
                                                , PkgRepo(..)
                                                )
import           Lib.Types.Emver                ( Version )
import           Orphans.Emver                  ( )
-- | Runtime settings to configure this application. These settings can be
-- loaded from various sources: defaults, environment variables, config files,
-- theoretically even a database.
type AppPort = Word16
data AppSettings = AppSettings
    { appDatabaseConf           :: PostgresConf
    , appHost                   :: HostPreference
    -- ^ Host/interface the server should bind to.
    , appPort                   :: AppPort
    -- ^ Port to listen on
    , appIpFromHeader           :: Bool
    -- ^ Get the IP address from the header when logging. Useful when sitting
    -- behind a reverse proxy.
    , appDetailedRequestLogging :: Bool
    -- ^ Use detailed request logging system
    , appShouldLogAll           :: Bool
    -- ^ Should all log messages be displayed?
    , resourcesDir              :: FilePath
    , sslPath                   :: FilePath
    , sslAuto                   :: Bool
    , registryHostname          :: Text
    , registryVersion           :: Version
    , sslKeyLocation            :: FilePath
    , sslCsrLocation            :: FilePath
    , sslCertLocation           :: FilePath
    , torPort                   :: AppPort
    , staticBinDir              :: FilePath
    , errorLogRoot              :: FilePath
    , marketplaceName           :: Text
    }
instance Has PkgRepo AppSettings where
    extract = liftA2 PkgRepo ((</> "apps") . resourcesDir) staticBinDir
    update f r =
        let repo = f $ extract r in r { resourcesDir = pkgRepoFileRoot repo, staticBinDir = pkgRepoAppMgrBin repo }
instance Has EosRepo AppSettings where
    extract = EosRepo . (</> "eos") . resourcesDir
    update f ctx =
        let repo     = f $ extract ctx
            settings = ctx { resourcesDir = takeDirectory (eosRepoFileRoot repo) }
        in  settings


instance FromJSON AppSettings where
    parseJSON = withObject "AppSettings" $ \o -> do
        appDatabaseConf           <- o .: "database"
        appHost                   <- fromString <$> o .: "host"
        appPort                   <- o .: "port"
        appIpFromHeader           <- o .: "ip-from-header"
        appDetailedRequestLogging <- o .:? "detailed-logging" .!= True
        appShouldLogAll           <- o .:? "should-log-all" .!= False
        resourcesDir              <- o .: "resources-path"
        sslPath                   <- o .: "ssl-path"
        sslAuto                   <- o .: "ssl-auto"
        registryHostname          <- o .: "registry-hostname"
        torPort                   <- o .: "tor-port"
        staticBinDir              <- o .: "static-bin-dir"
        errorLogRoot              <- o .: "error-log-root"

        let sslKeyLocation  = sslPath </> "key.pem"
        let sslCsrLocation  = sslPath </> "certificate.csr"
        let sslCertLocation = sslPath </> "certificate.pem"
        let registryVersion = fromJust . parseMaybe parseJSON . String . toS . showVersion $ version

        marketplaceName <- o .: "marketplace-name"

        return AppSettings { .. }

-- | Raw bytes at compile time of @config/settings.yml@
configSettingsYmlBS :: ByteString
configSettingsYmlBS = $(embedFile configSettingsYml)

-- | @config/settings.yml@, parsed to a @Value@.
configSettingsYmlValue :: Value
configSettingsYmlValue = either Exception.throw id $ decodeEither' configSettingsYmlBS

-- | A version of @AppSettings@ parsed at compile time from @config/settings.yml@.
compileTimeAppSettings :: AppSettings
compileTimeAppSettings = case fromJSON $ applyEnvValue False mempty configSettingsYmlValue of
    Error   e        -> panic $ toS e
    Success settings -> settings
