{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns    #-}
module Handler.Types.Status where

import           Startlude hiding (toLower)

import           Data.Aeson
import           Yesod.Core.Content

import           Lib.Types.Emver
import           Orphans.Emver                  ( )
import           Data.Text

data AppVersionRes = AppVersionRes
    { appVersionVersion      :: Version
    , appVersionMinCompanion :: Maybe Version
    , appVersionReleaseNotes :: Maybe Text
    }
    deriving (Eq, Show)
instance ToJSON AppVersionRes where
    toJSON AppVersionRes { appVersionVersion, appVersionMinCompanion, appVersionReleaseNotes } =
        let rn = case appVersionReleaseNotes of
                Nothing -> []
                Just x  -> ["release-notes" .= x]
            mc = case appVersionMinCompanion of
                Nothing -> []
                Just x  -> ["minCompanion" .= x]
        in  object $ ["version" .= appVersionVersion] <> mc <> rn
instance ToContent AppVersionRes where
    toContent = toContent . toJSON
instance ToTypedContent AppVersionRes where
    toTypedContent = toTypedContent . toJSON

-- Ugh
instance ToContent (Maybe AppVersionRes) where
    toContent = toContent . toJSON
instance ToTypedContent (Maybe AppVersionRes) where
    toTypedContent = toTypedContent . toJSON

-- status - nothing, available, instuctions
-- version - semver string

data SystemStatus = NOTHING | AVAILABLE | INSTRUCTIONS
    deriving (Eq, Show)
instance ToJSON SystemStatus where
    toJSON = String . toLower . show

data OSVersionRes = OSVersionRes
    { osVersionStatus :: SystemStatus
    , osVersionVersion :: Version
    } deriving (Eq, Show)
instance ToJSON OSVersionRes where
    toJSON OSVersionRes { .. } =  object ["status" .= osVersionStatus, "version" .= osVersionVersion]
instance ToContent OSVersionRes where
    toContent = toContent . toJSON
instance ToTypedContent OSVersionRes where
    toTypedContent = toTypedContent . toJSON