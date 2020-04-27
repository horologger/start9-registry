{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE RecordWildCards  #-}

module Handler.Icons where

import           Startlude

import           Data.Conduit
import qualified Data.Conduit.Binary as CB
import           System.Directory
import           Yesod.Core

import           Foundation
import           Lib.Registry
import           Settings
import           System.FilePath ((</>))

getIconsR :: Extension "png" -> Handler TypedContent
getIconsR ext = do
    AppSettings{..} <- appSettings <$> getYesod
    mPng <- liftIO $ getUnversionedFileFromDir (resourcesDir </> "icons") ext
    case mPng of
        Nothing -> notFound
        Just pngPath -> do
            putStrLn @Text $ show pngPath
            exists <- liftIO $ doesFileExist pngPath
            if exists
                then respondSource typePlain $ CB.sourceFile pngPath .| awaitForever sendChunkBS
                else notFound
