package manager

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSMTPNetworkProbeCompletesCertificateValidatedSTARTTLSWithoutAuthentication(t *testing.T) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		t.Fatal(err)
	}
	serverCertificate := tls.Certificate{Certificate: [][]byte{certificateDER}, PrivateKey: privateKey}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	type fixtureResult struct {
		commands []string
		err      error
	}
	finished := make(chan fixtureResult, 1)
	go func() {
		commands, fixtureErr := serveSTARTTLSFixture(listener, serverCertificate)
		finished <- fixtureResult{commands: commands, err: fixtureErr}
	}()

	config := smtpProbeConfig{
		Host:       "127.0.0.1",
		Port:       listener.Addr().(*net.TCPAddr).Port,
		EnableTLS:  true,
		Timeout:    5 * time.Second,
		ClientName: "tautweekly.local",
	}
	dependencies := defaultSMTPProbeDependencies(config.Timeout)
	dependencies.tlsConfig = func(host string) *tls.Config {
		return &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12, RootCAs: roots}
	}
	if err := probeSMTPNetwork(context.Background(), config, dependencies); err != nil {
		t.Fatal(err)
	}
	select {
	case fixture := <-finished:
		if fixture.err != nil {
			t.Fatal(fixture.err)
		}
		if len(fixture.commands) < 4 || !strings.HasPrefix(fixture.commands[0], "EHLO ") || fixture.commands[1] != "STARTTLS" || !strings.HasPrefix(fixture.commands[2], "EHLO ") || fixture.commands[3] != "QUIT" {
			t.Fatalf("unexpected STARTTLS preflight command sequence: %v", fixture.commands)
		}
		for _, command := range fixture.commands {
			for _, forbidden := range []string{"AUTH", "MAIL FROM", "RCPT TO", "DATA"} {
				if strings.HasPrefix(strings.ToUpper(command), forbidden) {
					t.Fatalf("STARTTLS preflight sent forbidden command %q", command)
				}
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("STARTTLS fixture did not complete")
	}
}

func TestSMTPDestinationFailuresDistinguishSyntaxFromUnsafeResolution(t *testing.T) {
	dependencies := smtpProbeDependencies{
		lookupIP: func(context.Context, string, string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("0.0.0.0")}, nil
		},
		dialContext: func(context.Context, string, string) (net.Conn, error) {
			t.Fatal("unsafe destination reached dial step")
			return nil, errors.New("unreachable")
		},
		tlsConfig: func(string) *tls.Config { return &tls.Config{} },
	}
	invalid := smtpProbeConfig{Host: "smtp://smtp.example.com", Port: 587, Timeout: time.Second}
	if err := probeSMTPNetwork(context.Background(), invalid, dependencies); !errors.Is(err, errSMTPHost) {
		t.Fatalf("invalid SMTP syntax classification: got %v", err)
	}
	unsafe := smtpProbeConfig{Host: "smtp.example.com", Port: 587, Timeout: time.Second}
	if err := probeSMTPNetwork(context.Background(), unsafe, dependencies); !errors.Is(err, errSMTPUnsafeAddress) {
		t.Fatalf("unsafe SMTP resolution classification: got %v", err)
	}
	if !validSMTPHost("smtp.example.com") || !allowedSMTPIP(net.ParseIP("192.0.2.10")) || !allowedSMTPIP(net.ParseIP("2001:db8::10")) {
		t.Fatal("valid SMTP host or public unicast address was rejected")
	}
}

func serveSTARTTLSFixture(listener net.Listener, certificate tls.Certificate) ([]string, error) {
	connection, err := listener.Accept()
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	commands := []string{}
	reader := bufio.NewReader(connection)
	writer := bufio.NewWriter(connection)
	if _, err := writer.WriteString("220 smtp.fixture.test ESMTP\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("250-smtp.fixture.test\r\n250-STARTTLS\r\n250 SIZE 1024\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("220 begin TLS\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	tlsConnection := tls.Server(connection, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
	if err := tlsConnection.Handshake(); err != nil {
		return commands, err
	}
	reader = bufio.NewReader(tlsConnection)
	writer = bufio.NewWriter(tlsConnection)
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("250 smtp.fixture.test\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	return commands, nil
}

func TestSMTPNetworkCheckStopsBeforeAuthenticationOrDelivery(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	commands := make(chan []string, 1)
	go serveSMTPPreflightFixture(listener, false, commands)

	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"SmtpHost":      "127.0.0.1",
		"SmtpPort":      int64(listener.Addr().(*net.TCPAddr).Port),
		"SmtpEnableSsl": false,
	})
	view := ReadConfigEditor(root)
	result, err := RunSMTPNetworkCheck(context.Background(), root, SMTPNetworkCheckRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "warning" || result.State != "warning" || result.Security != "plaintext-configured" {
		t.Fatalf("unexpected SMTP preflight result: %+v", result)
	}
	select {
	case observed := <-commands:
		if len(observed) == 0 || !strings.HasPrefix(observed[0], "EHLO ") {
			t.Fatalf("SMTP preflight omitted EHLO: %v", observed)
		}
		for _, forbidden := range []string{"AUTH", "MAIL FROM", "RCPT TO", "DATA"} {
			for _, command := range observed {
				if strings.HasPrefix(strings.ToUpper(command), forbidden) {
					t.Fatalf("SMTP preflight sent forbidden command %q", command)
				}
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("SMTP fixture did not complete")
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{"127.0.0.1", "fictional-smtp-secret", "newsletter@example.org"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("SMTP preflight returned private value %q", private)
		}
	}
}

func TestSMTPNetworkCheckRequiresAdvertisedSTARTTLS(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	commands := make(chan []string, 1)
	go serveSMTPPreflightFixture(listener, false, commands)

	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"SmtpHost":      "127.0.0.1",
		"SmtpPort":      int64(listener.Addr().(*net.TCPAddr).Port),
		"SmtpEnableSsl": true,
	})
	view := ReadConfigEditor(root)
	result, err := RunSMTPNetworkCheck(context.Background(), root, SMTPNetworkCheckRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "failed" || result.State != "failed" || result.Security != "not-established" || !strings.Contains(result.Summary, "STARTTLS") {
		t.Fatalf("missing STARTTLS was not reported safely: %+v", result)
	}
	select {
	case <-commands:
	case <-time.After(3 * time.Second):
		t.Fatal("SMTP fixture did not complete")
	}
}

func serveSMTPPreflightFixture(listener net.Listener, advertiseSTARTTLS bool, observed chan<- []string) {
	commands := []string{}
	defer func() { observed <- commands }()
	connection, err := listener.Accept()
	if err != nil {
		return
	}
	defer connection.Close()
	reader := bufio.NewReader(connection)
	writer := bufio.NewWriter(connection)
	_, _ = writer.WriteString("220 smtp.fixture.test ESMTP\r\n")
	_ = writer.Flush()
	for {
		line, readErr := reader.ReadString('\n')
		if readErr != nil {
			return
		}
		line = strings.TrimSpace(line)
		commands = append(commands, line)
		switch {
		case strings.HasPrefix(strings.ToUpper(line), "EHLO "):
			_, _ = writer.WriteString("250-smtp.fixture.test\r\n")
			if advertiseSTARTTLS {
				_, _ = writer.WriteString("250-STARTTLS\r\n")
			}
			_, _ = writer.WriteString("250 SIZE 1024\r\n")
			_ = writer.Flush()
		case strings.EqualFold(line, "QUIT"):
			_, _ = writer.WriteString("221 bye\r\n")
			_ = writer.Flush()
			return
		default:
			_, _ = writer.WriteString("500 unsupported\r\n")
			_ = writer.Flush()
			return
		}
	}
}

func setIntegrationConfigValues(t *testing.T, root string, updates map[string]any) {
	t.Helper()
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]any{}
	if err := json.Unmarshal(raw, &values); err != nil {
		t.Fatal(err)
	}
	for name, value := range updates {
		values[name] = value
	}
	raw, err = json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if view := ReadConfigEditor(root); !view.Valid || view.State != "ready" {
		t.Fatalf("updated fixture configuration is not ready: %+v", view.Issues)
	}
}

func TestIntegrationCheckOverallTreatsOptionalDirectPlexSkipAsPassed(t *testing.T) {
	steps := []IntegrationCheckStep{
		{Service: "tautulli", State: "passed"},
		{Service: "plex", State: "skipped"},
	}
	if result := integrationCheckOverall(steps); result != "passed" {
		t.Fatalf("optional Plex result: got %q, want passed", result)
	}
	steps[1].State = "failed"
	if result := integrationCheckOverall(steps); result != "failed" {
		t.Fatalf("failed Plex result: got %q, want failed", result)
	}
}

func TestRealIntegrationCheckRequiresConfirmationRevisionAndLAN(t *testing.T) {
	root := integrationConfigRoot(t, "http://203.0.113.10:8181", "fictional-api-key", "", "")
	view := ReadConfigEditor(root)
	_, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision}, time.Now)
	if !errors.Is(err, ErrRealCheckConfirmation) {
		t.Fatalf("missing confirmation error: got %v", err)
	}
	_, err = RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: "stale", ConfirmRealNetwork: true}, time.Now)
	if !errors.Is(err, ErrConfigConflict) {
		t.Fatalf("stale revision error: got %v", err)
	}
	result, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "failed" || result.Steps[0].State != "failed" || !strings.Contains(result.Steps[0].Summary, "private or loopback") {
		t.Fatalf("public destination was not blocked safely: %+v", result)
	}
}

func TestSuggestedPreviewUserIDRequiresOneExplicitRole(t *testing.T) {
	tests := []struct {
		name  string
		users []DiscoveredUser
		want  string
	}{
		{name: "no inferred role", users: []DiscoveredUser{{ID: "1", Name: "Owner-like name"}}},
		{name: "one administrator", users: []DiscoveredUser{{ID: "1", Role: "administrator"}}, want: "1"},
		{name: "legacy-excluded administrator", users: []DiscoveredUser{{ID: "1", Role: "administrator", LegacyRuleExcluded: true}}},
		{name: "included administrator after excluded owner", users: []DiscoveredUser{{ID: "1", Role: "owner", LegacyRuleExcluded: true}, {ID: "2", Role: "administrator"}}, want: "2"},
		{name: "ambiguous administrators", users: []DiscoveredUser{{ID: "1", Role: "administrator"}, {ID: "2", Role: "administrator"}}},
		{name: "owner preferred", users: []DiscoveredUser{{ID: "1", Role: "administrator"}, {ID: "2", Role: "owner"}}, want: "2"},
		{name: "ambiguous owners", users: []DiscoveredUser{{ID: "1", Role: "owner"}, {ID: "2", Role: "owner"}, {ID: "3", Role: "administrator"}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := suggestedPreviewUserID(test.users); got != test.want {
				t.Fatalf("suggestedPreviewUserID() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestDiscoveryMatchesLegacyRulesAgainstEffectiveFallbackOnly(t *testing.T) {
	names := []map[string]any{{"user_id": "1", "friendly_name": "Synthetic Managed"}, {"user_id": "2", "friendly_name": "Synthetic Native"}}
	details := []map[string]any{
		{"user_id": "1", "friendly_name": "Synthetic Managed", "email": "", "is_active": float64(1), "is_admin": float64(1)},
		{"user_id": "2", "friendly_name": "Synthetic Native", "email": "native@example.org", "is_active": float64(1), "is_owner": float64(1)},
	}
	legacy := map[string]struct{}{"fallback@example.org": {}, "must-not-reroute@example.org": {}}
	overrides := map[string]string{"1": "fallback@example.org", "2": "must-not-reroute@example.org"}
	users, matched := normalizeDiscoveredUsers(names, details, legacy, overrides)
	if matched != 1 || len(users) != 2 || !users[0].LegacyRuleExcluded || users[1].LegacyRuleExcluded {
		t.Fatalf("effective fallback exclusion or native-email precedence was lost: users=%+v matched=%d", users, matched)
	}
	if users[0].Eligibility != "address-needed" || !users[0].NeedsDeliveryAddress || users[1].Eligibility != "eligible" {
		t.Fatalf("preview sampling eligibility was coupled to production address policy: %+v", users)
	}
}

func integrationConfigRoot(t *testing.T, tautulliURL, tautulliSecret, plexURL, plexSecret string) string {
	t.Helper()
	root := t.TempDir()
	config := map[string]any{
		"TautulliUrl":           tautulliURL,
		"ApiKey":                tautulliSecret,
		"PlexServerUrl":         plexURL,
		"PlexToken":             plexSecret,
		"MediaServer":           "silo",
		"SiloUrl":               tautulliURL,
		"SiloApiKey":            tautulliSecret,
		"FromEmail":             "newsletter@example.org",
		"ReplyToEmail":          "newsletter@example.org",
		"TestEmail":             "admin@example.org",
		"SmtpHost":              "smtp.example.test",
		"SmtpUseAuthentication": true,
		"SmtpUsername":          "newsletter@example.org",
		"SmtpPassword":          "fictional-smtp-secret",
	}
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if view := ReadConfigEditor(root); !view.Valid || view.State != "ready" {
		t.Fatalf("fixture configuration is not ready: %+v", view.Issues)
	}
	return root
}
