package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/meilisearch/meilisearch-go"
	"go.mongodb.org/mongosh-driver/v2/bson"
	"go.mongodb.org/mongosh-driver/v2/mongosh"
	"go.mongodb.org/mongosh-driver/v2/mongosh/options"
	"go.mongodb.org/mongosh-driver/v2/mongosh/readpref"
	"go.mongodb.org/mongosh-driver/v2/mongosh/writeconcern"
)

type Movie struct {
	ID          string    `bson:"_id" json:"id"`
	Title       string    `bson:"title" json:"title"`
	Year        int       `bson:"year" json:"year"`
	Rating      float64   `bson:"rating" json:"rating"`
	Genres      []string  `bson:"genres" json:"genres"`
	MeiliIndex  bool      `bson:"_meiliIndex" json:"-"`
	IndexedDate time.Time `bson:"indexedDate,omitempty" json:"-"`
}

// getenv returns the value of the environment variable named by the key,
// or def if the variable is not present or empty.
func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	uri := os.Getenv("MONGODB_URI")
	if uri == "" {
		log.Fatal("You must set your 'MONGODB_URI' environment variable")
	}

	// mongosh options
	serverAPI := options.ServerAPI(options.ServerAPIVersion1)
	opts := options.Client().
		ApplyURI(uri).
		SetServerAPIOptions(serverAPI).
		SetCompressors([]string{"zlib", "snappy", "zstd"}).
		SetMinPoolSize(5).
		SetMaxPoolSize(100).
		SetConnectTimeout(10 * time.Second).
		SetServerSelectionTimeout(5 * time.Second).
		SetMaxConnIdleTime(30 * time.Second).
		SetRetryWrites(true).
		SetWriteConcern(writeconcern.Majority()).
		SetReadPreference(readpref.Nearest())

	// Connect to mongosh
	client, err := mongosh.Connect(opts)
	if err != nil {
		panic(err)
	}
	defer func() {
		if err = client.Disconnect(context.TODO()); err != nil {
			panic(err)
		}
	}()

	// Test ping
	if err := client.Database("admin").
		RunCommand(context.TODO(), bson.D{{Key: "ping", Value: 1}}).
		Err(); err != nil {
		panic(err)
	}
	fmt.Println("✅ Connected to MongoDB")

	// --- Fetch documents from mongosh ---
	coll := client.Database("LibreChat").Collection("messages")

	// Example filter: only documents that should be indexed (_meiliIndex: true)
	// and only last 7 days
	oneWeekAgo := time.Now().Add(-7 * 24 * time.Hour)
	filter := bson.M{
		"_meiliIndex": true,
		"indexedDate": bson.M{"$gte": oneWeekAgo},
	}

	cur, err := coll.Find(context.TODO(), filter)
	if err != nil {
		log.Fatalf("mongosh find failed: %v", err)
	}
	defer cur.Close(context.TODO())

	var movies []Movie
	if err := cur.All(context.TODO(), &movies); err != nil {
		log.Fatalf("Cursor decode failed: %v", err)
	}

	fmt.Printf("📦 Got %d documents from MongoDB\n", len(movies))

	// --- Setup Meilisearch client ---
	host := getenv("MEILI_HOST", "http://localhost:7700")
	apiKey := os.Getenv("MEILI_API_KEY")
	meilisearchClient := meilisearch.New(host, meilisearch.WithAPIKey(apiKey))

	indexUid := "movies"
	index := meilisearchClient.Index(indexUid)

	// Index only if we found docs
	if len(movies) > 0 {
		taskInfo, err := index.AddDocuments(movies, meilisearch.StringPtr("id"))
		if err != nil {
			log.Fatalf("Failed to index documents: %v", err)
		}
		fmt.Printf("🚀 Indexing task: %+v\n", taskInfo)
	}

	fmt.Println("✅ Done")
}
