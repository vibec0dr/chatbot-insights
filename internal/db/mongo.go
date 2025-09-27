package db

import (
	"context"
	"time"

	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/readpref"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

// MongoClient is the concrete type returned to consumers.
type MongoClient struct {
	*mongo.Client
}

// NewClient creates a new MongoDB client with default settings.
func NewClient(ctx context.Context, uri string) (*MongoClient, error) {
	opts := options.Client().
		ApplyURI(uri).
		SetRetryWrites(true).
		SetWriteConcern(writeconcern.Majority()).
		SetReadPreference(readpref.Primary()).
		SetConnectTimeout(10 * time.Second).
		SetServerSelectionTimeout(5 * time.Second)

	client, err := mongo.Connect(opts)
	if err != nil {
		return nil, err
	}

	return &MongoClient{client}, nil
}

// Ping checks the connection.
func (c *MongoClient) Ping(ctx context.Context) error {
	return c.Database("admin").RunCommand(ctx, map[string]int{"ping": 1}).Err()
}
