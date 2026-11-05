package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactedConfigNeverExposesSiloKeys(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	config := `{
  "MediaServer": "silo",
  "SiloUrl": "http://silo.fictional.test:8080",
  "SiloApiKey": "sa_fictional_monitor_key",
  "SiloCatalogApiKey": "sa_fictional_catalog_key"
}`
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadRedactedConfig(root)
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"sa_fictional_monitor_key", "sa_fictional_catalog_key"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("redacted response contains Silo key %q", secret)
		}
	}
	configured := 0
	for _, field := range view.Fields {
		if field.Name == "SiloApiKey" || field.Name == "SiloCatalogApiKey" {
			if field.Type != "secret" || field.Secret == nil || !field.Secret.Configured {
				t.Fatalf("Silo key %s is not reported as a configured secret: %+v", field.Name, field)
			}
			configured++
		}
	}
	if configured != 2 {
		t.Fatalf("expected both Silo keys in the redacted view, found %d", configured)
	}
}

func TestSiloMediaServerDoesNotRequireTautulliKey(t *testing.T) {
	t.Parallel()
	issues := map[string]string{}
	validateConfigRelationships(map[string]any{"MediaServer": "Silo"}, issues)
	if _, present := issues["ApiKey"]; present {
		t.Fatalf("Silo configuration was asked for a Tautulli API key: %v", issues)
	}
	issues = map[string]string{}
	validateConfigRelationships(map[string]any{"MediaServer": "tautulli"}, issues)
	if _, present := issues["ApiKey"]; !present {
		t.Fatal("Tautulli configuration no longer requires its API key")
	}
	issues = map[string]string{}
	validateConfigRelationships(map[string]any{}, issues)
	if _, present := issues["ApiKey"]; !present {
		t.Fatal("default configuration no longer requires the Tautulli API key")
	}
}
