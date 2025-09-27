package search

import (
	"fmt"

	"github.com/meilisearch/meilisearch-go"
)

// Client is the concrete MeiliSearch client.
type Client struct {
	meilisearch.ServiceManager
}

// NewClient constructs a new MeiliSearch client.
func NewClient(host, apiKey string) *Client {
	client := meilisearch.New(host, meilisearch.WithAPIKey(apiKey))

	return &Client{
		ServiceManager: client,
	}
}

// IndexDocument indexes a single document into a MeiliSearch index.
func (c *Client) IndexDocument(index string, doc interface{}) error {
	_, err := c.Index(index).AddDocuments([]interface{}{doc})
	if err != nil {
		return fmt.Errorf("failed to index document: %w", err)
	}
	return nil
}

// Search executes a search query.
func (c *Client) Search(index, query string) (*meilisearch.SearchResponse, error) {
	resp, err := c.Index(index).Search(query, &meilisearch.SearchRequest{})
	if err != nil {
		return nil, fmt.Errorf("search failed: %w", err)
	}
	return resp, nil
}
