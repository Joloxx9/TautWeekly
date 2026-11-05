package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Silo support for the Manager. The renderer reads Silo through its own
// Silo-Provider.ps1 module; these helpers give the Manager the same view for
// connection checks, guided library/user choices, and household lookups.
// Only Silo's native /api/v2 contract is used and only with GET requests.

const siloMaximumPages = 20

type siloCredentials struct {
	base       *url.URL
	monitorKey string
	catalogKey string
	profileID  string
}

func siloConfigCredentials(values map[string]any) (siloCredentials, error) {
	base, err := parseLANBaseURL(configMapString(values, "SiloUrl"))
	if err != nil {
		return siloCredentials{}, err
	}
	monitorKey := configMapString(values, "SiloApiKey")
	if monitorKey == "" {
		return siloCredentials{}, errIntegrationResponse
	}
	catalogKey := configMapString(values, "SiloCatalogApiKey")
	if catalogKey == "" {
		catalogKey = monitorKey
	}
	return siloCredentials{base: base, monitorKey: monitorKey, catalogKey: catalogKey, profileID: configMapString(values, "SiloProfileId")}, nil
}

// siloGet performs one GET and decodes the JSON body. HTTP 429/503 answers are
// retried a few times, honoring a short Retry-After.
func siloGet(ctx context.Context, client *http.Client, base *url.URL, key, profileID, path string, query url.Values, target any) error {
	endpoint := integrationEndpoint(base, path)
	if len(query) > 0 {
		endpoint.RawQuery = query.Encode()
	}
	for attempt := 0; ; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return errIntegrationResponse
		}
		request.Header.Set("Accept", "application/json")
		request.Header.Set("Authorization", "Bearer "+key)
		if profileID != "" {
			request.Header.Set("X-Profile-Id", profileID)
		}
		response, err := client.Do(request)
		if err != nil {
			return classifyIntegrationTransportError(err)
		}
		if (response.StatusCode == http.StatusTooManyRequests || response.StatusCode == http.StatusServiceUnavailable) && attempt < 3 {
			delay := 2 * time.Second
			if seconds, parseErr := strconv.Atoi(strings.TrimSpace(response.Header.Get("Retry-After"))); parseErr == nil && seconds >= 0 {
				delay = time.Duration(min(seconds, 5)) * time.Second
			}
			response.Body.Close()
			select {
			case <-ctx.Done():
				return context.DeadlineExceeded
			case <-time.After(delay):
			}
			continue
		}
		body, readErr := readLimitedIntegrationBody(response.Body)
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
				return fmt.Errorf("authentication rejected: HTTP %d", response.StatusCode)
			}
			return fmt.Errorf("unexpected HTTP status: %d", response.StatusCode)
		}
		if readErr != nil {
			return readErr
		}
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.UseNumber()
		if decoder.Decode(target) != nil {
			return errIntegrationResponse
		}
		return nil
	}
}

type siloPage struct {
	Items []map[string]any `json:"items"`
	Page  struct {
		HasMore    bool   `json:"has_more"`
		NextCursor string `json:"next_cursor"`
	} `json:"page"`
}

func siloPaged(ctx context.Context, client *http.Client, base *url.URL, key, profileID, path string, query url.Values) ([]map[string]any, error) {
	items := []map[string]any{}
	cursor := ""
	for page := 0; page < siloMaximumPages; page++ {
		pageQuery := url.Values{}
		for name, value := range query {
			pageQuery[name] = value
		}
		if cursor != "" {
			pageQuery.Set("cursor", cursor)
		}
		var document siloPage
		if err := siloGet(ctx, client, base, key, profileID, path, pageQuery, &document); err != nil {
			return nil, err
		}
		items = append(items, document.Items...)
		if !document.Page.HasMore || strings.TrimSpace(document.Page.NextCursor) == "" || len(items) >= maximumDiscoveryChoices {
			break
		}
		cursor = document.Page.NextCursor
	}
	return items, nil
}

func siloString(value any) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(value))
}

// siloTautulliUser maps a Silo account onto the Tautulli roster fields the
// existing discovery normalizers already understand.
func siloTautulliUser(account map[string]any) map[string]any {
	// Tautulli-style "1"/"0" flags, as the shared normalizers expect.
	active := "1"
	if enabled, ok := account["enabled"].(bool); ok && !enabled {
		active = "0"
	}
	admin := "0"
	if strings.EqualFold(siloString(account["role"]), "admin") {
		admin = "1"
	}
	return map[string]any{
		"user_id":       siloString(account["id"]),
		"username":      siloString(account["username"]),
		"friendly_name": siloString(account["username"]),
		"email":         siloString(account["email"]),
		"is_active":     active,
		"is_admin":      admin,
		"deleted_user":  "0",
	}
}

func siloSectionType(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "movie", "movies":
		return "movie"
	case "series", "show", "shows", "tv", "mixed":
		return "show"
	}
	return strings.ToLower(strings.TrimSpace(kind))
}

func siloAccounts(ctx context.Context, client *http.Client, credentials siloCredentials) ([]map[string]any, error) {
	accounts, err := siloPaged(ctx, client, credentials.base, credentials.monitorKey, "", "api/v2/admin/users", url.Values{"limit": {"200"}})
	if err != nil {
		return nil, err
	}
	users := make([]map[string]any, 0, len(accounts))
	for _, account := range accounts {
		users = append(users, siloTautulliUser(account))
	}
	return users, nil
}

func siloCatalogProfile(ctx context.Context, client *http.Client, credentials siloCredentials) (string, error) {
	if credentials.profileID != "" {
		return credentials.profileID, nil
	}
	var document siloPage
	if err := siloGet(ctx, client, credentials.base, credentials.catalogKey, "", "api/v2/profiles", nil, &document); err != nil {
		return "", err
	}
	fallback := ""
	for _, profile := range document.Items {
		id := siloString(profile["id"])
		if id == "" {
			continue
		}
		if primary, _ := profile["is_primary"].(bool); primary {
			return id, nil
		}
		if child, _ := profile["is_child"].(bool); !child && fallback == "" {
			fallback = id
		}
	}
	if fallback == "" {
		return "", errIntegrationResponse
	}
	return fallback, nil
}

func siloLibraries(ctx context.Context, client *http.Client, credentials siloCredentials) ([]map[string]any, error) {
	profileID, err := siloCatalogProfile(ctx, client, credentials)
	if err != nil {
		return nil, err
	}
	var document siloPage
	if err := siloGet(ctx, client, credentials.base, credentials.catalogKey, profileID, "api/v2/user/libraries", nil, &document); err != nil {
		return nil, err
	}
	libraries := make([]map[string]any, 0, len(document.Items))
	for _, library := range document.Items {
		libraries = append(libraries, map[string]any{
			"section_id":   siloString(library["id"]),
			"section_name": siloString(library["name"]),
			"section_type": siloSectionType(siloString(library["type"])),
			"is_active":    "1",
		})
	}
	return libraries, nil
}

func verifySilo(ctx context.Context, client *http.Client, values map[string]any) IntegrationCheckStep {
	credentials, err := siloConfigCredentials(values)
	if err != nil {
		return failedIntegrationStep("silo", err)
	}
	for _, check := range []struct{ path, label string }{
		{"api/v2/admin/users/capabilities", "accounts"},
		{"api/v2/admin/playback-history/capabilities", "playback history"},
		{"api/v2/admin/catalog/capabilities", "catalog"},
	} {
		var capabilities map[string]any
		if err := siloGet(ctx, client, credentials.base, credentials.monitorKey, "", check.path, nil, &capabilities); err != nil {
			return failedIntegrationStep("silo", err)
		}
		if allowed, ok := capabilities["allowed"].(bool); ok && !allowed {
			return IntegrationCheckStep{Service: "silo", State: "failed", Summary: "The Silo API key is not allowed to read " + check.label + ". Use a key owned by an administrator with the admin:monitor:read scope."}
		}
	}
	users, err := siloAccounts(ctx, client, credentials)
	if err != nil {
		return failedIntegrationStep("silo", err)
	}
	libraries, err := siloLibraries(ctx, client, credentials)
	if err != nil {
		step := failedIntegrationStep("silo", err)
		step.Summary = "Silo monitoring access worked, but the catalog key could not list libraries. " + step.Summary
		return step
	}
	selectable := 0
	for _, library := range libraries {
		if kind := fmt.Sprint(library["section_type"]); kind == "movie" || kind == "show" {
			selectable++
		}
	}
	if selectable == 0 {
		return IntegrationCheckStep{Service: "silo", State: "failed", Summary: "Silo authentication worked, but the catalog key sees no movie or TV libraries."}
	}
	return IntegrationCheckStep{Service: "silo", State: "passed", Summary: fmt.Sprintf("Authenticated Silo API v2; %d accounts and %d movie/TV libraries were reported.", len(users), selectable)}
}

func discoverSiloChoices(ctx context.Context, values map[string]any, revision string, now func() time.Time) (TautulliDiscoveryResult, error) {
	credentials, err := siloConfigCredentials(values)
	if err != nil {
		return TautulliDiscoveryResult{}, err
	}
	checkContext, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	client := newLANOnlyHTTPClient()
	rawLibraries, err := siloLibraries(checkContext, client, credentials)
	if err != nil {
		return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("libraries", err)
	}
	libraries := normalizeDiscoveredLibraries(rawLibraries)
	if len(libraries) == 0 {
		return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("libraries", errIntegrationResponse)
	}
	rawUsers, err := siloAccounts(checkContext, client, credentials)
	if err != nil {
		return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("users", err)
	}
	legacyRules := normalizedLegacyExclusionRules(values["ExcludedEmails"])
	emailOverrides := normalizedDiscoveryUserEmailOverrides(values["UserEmailOverrides"])
	users, matchedLegacyRules := normalizeDiscoveredUsers(rawUsers, rawUsers, legacyRules, emailOverrides)
	if len(users) == 0 {
		return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("users", errIntegrationResponse)
	}
	return TautulliDiscoveryResult{
		PrimaryRecipientCount:  countDiscoveredPrimaryRecipients(rawUsers, values),
		Mode:                   "real-lan-discovery",
		NetworkBoundary:        "private-and-loopback-only",
		CompletedAtUTC:         now().UTC().Format(time.RFC3339),
		ConfigRevision:         revision,
		Libraries:              libraries,
		Users:                  users,
		SuggestedPreviewUserID: suggestedPreviewUserID(users),
		LegacyRuleCount:        len(legacyRules),
		MatchedLegacyRuleCount: matchedLegacyRules,
	}, nil
}

// siloUserDetail returns one account in the Tautulli get_user shape.
func siloUserDetail(ctx context.Context, values map[string]any, userID string) (map[string]any, error) {
	credentials, err := siloConfigCredentials(values)
	if err != nil {
		return nil, err
	}
	var account map[string]any
	if err := siloGet(ctx, newLANOnlyHTTPClient(), credentials.base, credentials.monitorKey, "", "api/v2/admin/users/"+url.PathEscape(userID), nil, &account); err != nil {
		return nil, err
	}
	return siloTautulliUser(account), nil
}
