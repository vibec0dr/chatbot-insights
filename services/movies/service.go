package movies

import (
	"context"
	"fmt"
)

// Consumer-side interfaces (for testing)
type Pinger interface {
	Ping(ctx context.Context) error
}

type Indexer interface {
	IndexDocument(index string, doc interface{}) error
}

// MovieService depends on concrete clients but uses interfaces in testing
type MovieService struct {
	dbClient     Pinger
	searchClient Indexer
}

// Constructor uses dependency injection
func NewMovieService(dbClient Pinger, searchClient Indexer) *MovieService {
	return &MovieService{
		dbClient:     dbClient,
		searchClient: searchClient,
	}
}

// HealthCheck pings MongoDB
func (s *MovieService) HealthCheck(ctx context.Context) error {
	return s.dbClient.Ping(ctx)
}

// IndexMovie indexes a movie into MeiliSearch
func (s *MovieService) IndexMovie(ctx context.Context, index string, movie interface{}) error {
	if err := s.searchClient.IndexDocument(index, movie); err != nil {
		return fmt.Errorf("indexing movie failed: %w", err)
	}
	return nil
}
