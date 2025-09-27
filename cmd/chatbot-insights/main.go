package main

import (
	"fmt"
	"net/http"

	"github.com/a-h/templ"
	"github.com/vibec0dr/chatbot-insights/web"
)

func main() {
	component := web.RootLayout()

	http.Handle("/", templ.Handler(component))

	fmt.Println("Listening on :8080")
	http.ListenAndServe(":8080", nil)
}
