package oci

import (
	"fmt"
	"os"
)

// JoinGroupNamespaces modifies spec so the container joins the Linux namespaces
// owned by the primary container (identified by primaryPID).
//
// isolation controls which namespaces are shared:
//   - "shared-network": joins network and uts namespaces
//   - "shared-ipc":     also joins ipc namespace (enables /dev/shm sharing for ROS2/dora-rs)
//   - anything else:    no-op
func JoinGroupNamespaces(spec *Spec, primaryPID uint32, isolation string) error {
	if spec.Linux == nil {
		return fmt.Errorf("JoinGroupNamespaces: spec.Linux is nil")
	}
	if primaryPID == 0 {
		return fmt.Errorf("JoinGroupNamespaces: primaryPID must be non-zero")
	}

	join := map[string]bool{}
	switch isolation {
	case "shared-ipc":
		join["ipc"] = true
		join["network"] = true
		join["uts"] = true
	case "shared-network":
		join["network"] = true
		join["uts"] = true
	default:
		return nil
	}

	for i, ns := range spec.Linux.Namespaces {
		if join[ns.Type] {
			nsPath := fmt.Sprintf("/proc/%d/ns/%s", primaryPID, ns.Type)
			// Verify the namespace path exists before writing it into the spec.
			// An absent path means the primary container has already exited;
			// fail fast rather than silently joining a recycled PID's namespace
			// (SOC2-CC6, NIST-SC-7: PID-reuse defence-in-depth).
			if _, err := os.Lstat(nsPath); err != nil {
				return fmt.Errorf("JoinGroupNamespaces: namespace path %q not available (primary container exited?): %w", nsPath, err)
			}
			spec.Linux.Namespaces[i].Path = nsPath
		}
	}
	return nil
}

// SharedSHMMount returns a bind-mount that maps hostSHMPath into /dev/shm.
// Use this for shared-ipc isolation where all services share one shm segment.
// hostSHMPath should be /run/wendy/shm/{appID}.
func SharedSHMMount(hostSHMPath string) Mount {
	return Mount{
		Destination: "/dev/shm",
		Type:        "bind",
		Source:      hostSHMPath,
		Options:     []string{"rbind", "rw"},
	}
}

// RemoveDefaultSHM removes the default per-container tmpfs /dev/shm mount from spec.
// Call this before adding a SharedSHMMount to avoid duplicate mounts.
func RemoveDefaultSHM(spec *Spec) {
	mounts := spec.Mounts[:0]
	for _, m := range spec.Mounts {
		if m.Destination != "/dev/shm" {
			mounts = append(mounts, m)
		}
	}
	spec.Mounts = mounts
}
