// Package discovery provides device discovery via mDNS and other transports.
package discovery

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/hashicorp/mdns"
	"github.com/wendylabsinc/wendy/internal/shared/models"
)

const (
	// wendyServiceType is the mDNS service type advertised by WendyOS devices.
	wendyServiceType = "_wendyos._tcp"

	// defaultTimeout is the default mDNS browse duration.
	defaultTimeout = 5 * time.Second
)

// DiscoveryOptions configures a device discovery scan.
type DiscoveryOptions struct {
	// Types limits discovery to the specified interface types.
	// An empty slice means discover all supported types.
	Types []models.InterfaceType

	// Timeout is the maximum duration for the discovery scan.
	// Zero uses the default timeout.
	Timeout time.Duration
}

// Discover runs device discovery across the requested interface types and returns
// all found devices. Currently only LAN (mDNS) discovery is implemented.
func Discover(ctx context.Context, opts DiscoveryOptions) (*models.DevicesCollection, error) {
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = defaultTimeout
	}

	collection := &models.DevicesCollection{}

	shouldDiscover := func(t models.InterfaceType) bool {
		if len(opts.Types) == 0 {
			return true
		}
		for _, ot := range opts.Types {
			if ot == t {
				return true
			}
		}
		return false
	}

	if shouldDiscover(models.InterfaceLAN) {
		devices, err := DiscoverLAN(ctx, timeout)
		if err != nil {
			return nil, fmt.Errorf("LAN discovery: %w", err)
		}
		collection.LANDevices = devices
	}

	// USB, Ethernet, and Bluetooth discovery are platform-specific and not yet
	// implemented in the Go port. They can be added here following the same pattern.

	return collection, nil
}

// DiscoverLAN uses mDNS to find WendyOS devices advertising _wendyos._tcp on the
// local network. Each discovered entry is converted to a LANDevice.
func DiscoverLAN(ctx context.Context, timeout time.Duration) ([]models.LANDevice, error) {
	if timeout == 0 {
		timeout = defaultTimeout
	}

	entriesCh := make(chan *mdns.ServiceEntry, 16)
	var devices []models.LANDevice

	// Collect results in a goroutine so the lookup can write to the channel.
	done := make(chan struct{})
	go func() {
		defer close(done)
		seen := make(map[string]bool)
		for entry := range entriesCh {
			hostname := entry.Host
			// hashicorp/mdns returns hostnames with a trailing dot; trim it.
			hostname = strings.TrimSuffix(hostname, ".")

			key := fmt.Sprintf("%s-%s-%d", entry.Name, hostname, entry.Port)
			if seen[key] {
				continue
			}
			seen[key] = true

			displayName := hostname
			// Strip .local suffix for a cleaner display name.
			displayName = strings.TrimSuffix(displayName, ".local")

			ipAddr := ""
			if entry.AddrV4 != nil {
				ipAddr = entry.AddrV4.String()
			} else if entry.AddrV6 != nil {
				ipAddr = entry.AddrV6.String()
			}

			// Extract id from TXT records if present (format: id=<value>).
			id := ""
			for _, txt := range entry.InfoFields {
				if k, v, ok := strings.Cut(txt, "="); ok && k == "id" {
					id = v
				}
			}
			if id == "" {
				id = displayName
			}

			devices = append(devices, models.LANDevice{
				ID:            id,
				DisplayName:   displayName,
				Hostname:      hostname,
				IPAddress:     ipAddr,
				Port:          entry.Port,
				InterfaceType: "LAN",
				IsWendyDevice: true,
			})
		}
	}()

	// Build a context-aware timeout: use whichever fires first.
	lookupCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	params := mdns.DefaultParams(wendyServiceType)
	params.Entries = entriesCh
	params.Timeout = timeout
	params.DisableIPv6 = false

	// mdns.Query is blocking; run it and then close the channel.
	err := mdns.Query(params)
	close(entriesCh)
	<-done

	// If the context was cancelled, surface that rather than the mdns error.
	if lookupCtx.Err() != nil {
		return devices, nil // return whatever we collected
	}
	if err != nil {
		return nil, fmt.Errorf("mDNS query: %w", err)
	}

	return devices, nil
}
