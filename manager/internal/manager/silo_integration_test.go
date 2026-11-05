package manager

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	fakeSiloMonitorKey = "sa_fictional_monitor_key"
	fakeSiloCatalogKey = "sa_fictional_catalog_key"
	fakeSiloProfileID  = "c0ffee00-0000-4000-8000-000000000001"
)

type fakeSilo struct {
	mu          sync.Mutex
	paths       []string
	rateLimited bool
	server      *httptest.Server
}

func newFakeSilo(t *testing.T) *fakeSilo {
	t.Helper()
	fake := &fakeSilo{}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.paths = append(fake.paths, r.URL.Path)
		firstLibraries := !fake.rateLimited && r.URL.Path == "/api/v2/user/libraries"
		if firstLibraries {
			fake.rateLimited = true
		}
		fake.mu.Unlock()
		if r.Method != http.MethodGet {
			t.Errorf("Manager sent %s to Silo", r.Method)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Query().Get("apikey") != "" || strings.Contains(r.URL.RawQuery, "sa_") {
			t.Errorf("Silo key appeared in a query string")
		}
		auth := r.Header.Get("Authorization")
		monitor := auth == "Bearer "+fakeSiloMonitorKey
		catalog := auth == "Bearer "+fakeSiloCatalogKey
		reply := func(value any) { _ = json.NewEncoder(w).Encode(value) }
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/v2/admin/") && !monitor:
			w.WriteHeader(http.StatusForbidden)
		case strings.HasSuffix(r.URL.Path, "/capabilities"):
			reply(map[string]any{"allowed": true})
		case r.URL.Path == "/api/v2/admin/users":
			if r.URL.Query().Get("cursor") == "" {
				reply(map[string]any{
					"items": []any{
						map[string]any{"id": "1", "username": "alice", "email": "alice@example.com", "role": "admin", "enabled": true},
						map[string]any{"id": "2", "username": "bob", "email": "bob@example.com", "role": "user", "enabled": true},
					},
					"page": map[string]any{"has_more": true, "next_cursor": "page-2"},
				})
				return
			}
			reply(map[string]any{
				"items": []any{
					map[string]any{"id": "3", "username": "carol", "email": "carol@example.com", "role": "user", "enabled": false},
					map[string]any{"id": "4", "username": "dave", "email": "", "role": "user", "enabled": true},
				},
				"page": map[string]any{"has_more": false},
			})
		case r.URL.Path == "/api/v2/admin/users/2":
			reply(map[string]any{"id": "2", "username": "bob", "email": "bob@example.com", "enabled": true})
		case r.URL.Path == "/api/v2/profiles":
			if !catalog {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			reply(map[string]any{"items": []any{
				map[string]any{"id": "kid-profile", "is_child": true},
				map[string]any{"id": fakeSiloProfileID, "is_primary": true},
			}})
		case r.URL.Path == "/api/v2/user/libraries":
			if !catalog || r.Header.Get("X-Profile-Id") != fakeSiloProfileID {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if firstLibraries {
				w.Header().Set("Retry-After", "0")
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			reply(map[string]any{"items": []any{
				map[string]any{"id": "10", "name": "Movies", "type": "movies"},
				map[string]any{"id": "11", "name": "Shows", "type": "series"},
				map[string]any{"id": "12", "name": "Books", "type": "ebooks"},
			}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func fakeSiloConfigRoot(t *testing.T, fake *fakeSilo) string {
	t.Helper()
	root := integrationConfigRoot(t, fake.server.URL, fakeSiloMonitorKey, "", "")
	setIntegrationConfigValues(t, root, map[string]any{"SiloCatalogApiKey": fakeSiloCatalogKey})
	return root
}

func TestSiloIntegrationCheckPassesWithoutReturningSecrets(t *testing.T) {
	fake := newFakeSilo(t)
	root := fakeSiloConfigRoot(t, fake)
	view := ReadConfigEditor(root)
	result, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "passed" || len(result.Steps) != 1 || result.Steps[0].Service != "silo" || !strings.Contains(result.Steps[0].Summary, "4 accounts and 2 movie/TV libraries") {
		t.Fatalf("unexpected Silo verification: %+v", result)
	}
	encoded, _ := json.Marshal(result)
	for _, private := range []string{fakeSiloMonitorKey, fakeSiloCatalogKey, fake.server.URL, "example.com"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("verification evidence leaked %q", private)
		}
	}
}

func TestSiloIntegrationCheckReportsRejectedMonitorKey(t *testing.T) {
	fake := newFakeSilo(t)
	root := fakeSiloConfigRoot(t, fake)
	setIntegrationConfigValues(t, root, map[string]any{"SiloApiKey": "sa_wrong_key"})
	view := ReadConfigEditor(root)
	result, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "failed" || !strings.Contains(result.Steps[0].Summary, "rejected the configured credential") {
		t.Fatalf("rejected key was not reported: %+v", result)
	}
}

func TestSiloDiscoveryReturnsSanitizedChoices(t *testing.T) {
	fake := newFakeSilo(t)
	root := fakeSiloConfigRoot(t, fake)
	view := ReadConfigEditor(root)
	result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatalf("%v: %v", err, errors.Unwrap(err))
	}
	if len(result.Libraries) != 2 || result.Libraries[0].MediaType != "movie" || result.Libraries[1].MediaType != "show" {
		t.Fatalf("unexpected Silo libraries: %+v", result.Libraries)
	}
	byName := map[string]DiscoveredUser{}
	for _, user := range result.Users {
		byName[user.Name] = user
	}
	if len(result.Users) != 4 || byName["alice"].Eligibility != "eligible" || byName["alice"].Role != "administrator" ||
		byName["carol"].Eligibility != "skipped" || !byName["dave"].NeedsDeliveryAddress {
		t.Fatalf("unexpected Silo users: %+v", result.Users)
	}
	if result.SuggestedPreviewUserID != "1" || result.PrimaryRecipientCount == nil || *result.PrimaryRecipientCount != 2 {
		t.Fatalf("unexpected preview suggestion or recipient count: %+v", result)
	}
	encoded, _ := json.Marshal(result)
	for _, private := range []string{fakeSiloMonitorKey, fakeSiloCatalogKey, fake.server.URL, "example.com"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("discovery leaked %q", private)
		}
	}
	if !fake.rateLimited {
		t.Fatal("rate-limit retry path was not exercised")
	}
}

func TestSiloDiscoveryRefusesPublicDestination(t *testing.T) {
	root := integrationConfigRoot(t, "http://8.8.8.8:8080", fakeSiloMonitorKey, "", "")
	view := ReadConfigEditor(root)
	if _, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now); err == nil {
		t.Fatal("public Silo destination was contacted")
	}
}

func TestSiloUserDetailUsesSelectedAccountOnly(t *testing.T) {
	fake := newFakeSilo(t)
	root := fakeSiloConfigRoot(t, fake)
	values, _, _, _ := readConfigDocument(root)
	detail, err := siloUserDetail(context.Background(), values, "2")
	if err != nil || detail["user_id"] != "2" || detail["email"] != "bob@example.com" {
		t.Fatalf("unexpected account detail: %+v %v", detail, err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.paths) != 1 || fake.paths[0] != "/api/v2/admin/users/2" {
		t.Fatalf("lookup was not selected-account only: %v", fake.paths)
	}
}
