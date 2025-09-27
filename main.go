package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

func main() {
	var uri string
	if uri = os.Getenv("MONGODB_URI"); uri == "" {
		log.Fatal("You must set your 'MONGODB_URI' environment variable. See\n\t https://docs.mongodb.com/drivers/go/current/usage-examples/")
	}

	// Set up the connection options
	serverAPI := options.ServerAPI(options.ServerAPIVersion1)
	opts := options.Client().
		ApplyURI(uri).
		SetServerAPIOptions(serverAPI).
		// Enable compression
		SetCompressors([]string{"zlib", "snappy", "zstd"}).
		// Connection pool settings
		SetMinPoolSize(5).
		SetMaxPoolSize(100).
		// Connection timeout settings
		SetConnectTimeout(10 * time.Second).
		SetServerSelectionTimeout(5 * time.Second).
		// Keep idle connections alive
		SetMaxConnIdleTime(30 * time.Second).
		// Enable retries for better reliability
		SetRetryWrites(true).
		// Write concern for better reliability
		SetWriteConcern(writeconcern.Majority()).
		SetWriteConcern(mongo.WriteConcern{}.SetW("majority")).
		// Read preference for better performance
		SetReadPreference(mongo.ReadPref{}.Primary())

	// Creates a new client and connects to the server
	client, err := mongo.Connect(context.TODO(), opts)
	if err != nil {
		panic(err)
	}
	defer func() {
		if err = client.Disconnect(context.TODO()); err != nil {
			panic(err)
		}
	}()

	// Sends a ping to confirm a successful connection
	var result bson.M
	if err := client.Database("admin").RunCommand(context.TODO(), bson.D{{"ping", 1}}).Decode(&result); err != nil {
		panic(err)
	}
	fmt.Println("Pinged your deployment. You successfully connected to MongoDB!")
}
