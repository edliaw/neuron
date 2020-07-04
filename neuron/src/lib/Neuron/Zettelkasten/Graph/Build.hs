{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Zettelkasten.Graph.Build
  ( buildZettelkasten,
  )
where

import Control.Monad.Writer (runWriterT)
import qualified Data.Graph.Labelled as G
import qualified Data.Map.Strict as Map
import Neuron.Zettelkasten.Connection
import Neuron.Zettelkasten.Graph.Type
import Neuron.Zettelkasten.ID
import Neuron.Zettelkasten.Query.Error (QueryError)
import Neuron.Zettelkasten.Query.Eval (queryConnections)
import Neuron.Zettelkasten.Zettel
import Neuron.Zettelkasten.Zettel.Format
import Neuron.Zettelkasten.Zettel.Parser
import Relude
import Relude.Extra.Group
import System.FilePath

buildZettelkasten ::
  [(ZettelFormat, ZettelReader, [(FilePath, Text)])] ->
  ( ZettelGraph,
    [ZettelC],
    Map ZettelID ZettelError
  )
buildZettelkasten filesPerFormat =
  let allFiles = concatMap (\(_, _, filesWithContent) -> fmap fst filesWithContent) filesPerFormat
      groupedFiles = groupBy (toText . takeBaseName) allFiles
      duplicates = Map.filter (\files -> length files > 1) groupedFiles
      filterUnique (format, zreader, filesWithContent) =
        ( format,
          zreader,
          filter
            (\(file, _) -> Map.notMember (toText $ takeBaseName file) duplicates)
            filesWithContent
        )
      zs = parseZettels $ fmap filterUnique filesPerFormat
      parseErrors = Map.fromList $ lefts zs <&> (zettelID &&& zettelError)
      (g, queryErrors) = mkZettelGraph $ fmap sansContent zs
      errors =
        Map.unions
          [ fmap ZettelError_ParseError parseErrors,
            fmap ZettelError_QueryErrors queryErrors,
            fmap ZettelError_AmbiguousFiles $ Map.mapKeys parseZettelID duplicates
          ]
   in (g, zs, errors)

-- | Build the Zettelkasten graph from a list of zettels
--
-- If there are any errors during parsing of queries (to determine connections),
-- return them as well.
mkZettelGraph ::
  [Zettel] ->
  ( ZettelGraph,
    Map ZettelID (NonEmpty QueryError)
  )
mkZettelGraph zettels =
  let res :: [(Zettel, ([(Maybe Connection, Zettel)], [QueryError]))] =
        flip fmap zettels $ \z ->
          (z, runQueryConnections zettels z)
      g :: ZettelGraph = G.mkGraphFrom zettels $ flip concatMap res $ \(z1, fst -> conns) ->
        edgeFromConnection z1 <$> conns
      errors = Map.fromList $ flip mapMaybe res $ \(z, (nonEmpty . snd -> merrs)) ->
        (zettelID z,) <$> merrs
   in (g, errors)

runQueryConnections :: [Zettel] -> Zettel -> ([(Maybe Connection, Zettel)], [QueryError])
runQueryConnections zettels z =
  flip runReader zettels $ do
    runWriterT $ queryConnections z

edgeFromConnection :: Zettel -> (Maybe Connection, Zettel) -> (Maybe Connection, Zettel, Zettel)
edgeFromConnection z (c, z2) =
  (connectionMonoid $ fromMaybe Folgezettel c, z, z2)
  where
    -- Our connection monoid will never be Nothing (mempty); see the note in
    -- type `ZettelGraph`.
    connectionMonoid = Just
