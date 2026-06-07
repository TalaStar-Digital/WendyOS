package oci

import (
	"fmt"
	"os"
	"runtime"
	"testing"
)

// requireLinux skips the test on non-Linux platforms where /proc is unavailable.
func requireLinux(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skipf("procfs namespace paths are only available on Linux (running %s)", runtime.GOOS)
	}
}

func TestJoinGroupNamespaces_SharedIPC(t *testing.T) {
	requireLinux(t)
	// Use the current process PID — guaranteed to have valid namespace paths.
	pid := uint32(os.Getpid())
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	if err := JoinGroupNamespaces(spec, pid, "shared-ipc"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	nsMap := make(map[string]string)
	for _, ns := range spec.Linux.Namespaces {
		nsMap[ns.Type] = ns.Path
	}
	if nsMap["ipc"] != fmt.Sprintf("/proc/%d/ns/ipc", pid) {
		t.Errorf("ipc namespace path = %q, want /proc/%d/ns/ipc", nsMap["ipc"], pid)
	}
	if nsMap["network"] != fmt.Sprintf("/proc/%d/ns/network", pid) {
		t.Errorf("network namespace path = %q, want /proc/%d/ns/network", nsMap["network"], pid)
	}
	if nsMap["uts"] != fmt.Sprintf("/proc/%d/ns/uts", pid) {
		t.Errorf("uts namespace path = %q, want /proc/%d/ns/uts", nsMap["uts"], pid)
	}
	if nsMap["pid"] != "" {
		t.Errorf("pid namespace should not be joined, got %q", nsMap["pid"])
	}
}

func TestJoinGroupNamespaces_SharedNetwork(t *testing.T) {
	requireLinux(t)
	pid := uint32(os.Getpid())
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	if err := JoinGroupNamespaces(spec, pid, "shared-network"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	nsMap := make(map[string]string)
	for _, ns := range spec.Linux.Namespaces {
		nsMap[ns.Type] = ns.Path
	}
	if nsMap["network"] != fmt.Sprintf("/proc/%d/ns/network", pid) {
		t.Errorf("network namespace path = %q, want /proc/%d/ns/network", nsMap["network"], pid)
	}
	if nsMap["uts"] != fmt.Sprintf("/proc/%d/ns/uts", pid) {
		t.Errorf("uts namespace path = %q, want /proc/%d/ns/uts", nsMap["uts"], pid)
	}
	// ipc should remain isolated in shared-network mode
	if nsMap["ipc"] != "" {
		t.Errorf("ipc namespace should not be joined in shared-network mode, got %q", nsMap["ipc"])
	}
}

func TestJoinGroupNamespaces_Isolated(t *testing.T) {
	// "isolated" mode is a no-op — no namespace paths are set regardless of
	// platform, so no requireLinux needed.
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	if err := JoinGroupNamespaces(spec, 9999, "isolated"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, ns := range spec.Linux.Namespaces {
		if ns.Path != "" {
			t.Errorf("isolated mode should not join any namespaces, but %q has path %q", ns.Type, ns.Path)
		}
	}
}

func TestJoinGroupNamespaces_ZeroPID(t *testing.T) {
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	if err := JoinGroupNamespaces(spec, 0, "shared-ipc"); err == nil {
		t.Fatal("expected error for zero PID, got nil")
	}
}

func TestJoinGroupNamespaces_NilLinux(t *testing.T) {
	spec := &Spec{}
	if err := JoinGroupNamespaces(spec, 1234, "shared-ipc"); err == nil {
		t.Fatal("expected error for nil Linux, got nil")
	}
}

func TestJoinGroupNamespaces_StaleProcess(t *testing.T) {
	requireLinux(t)
	// PID 2^22 is beyond the Linux default PID limit (4M) and will not exist.
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	if err := JoinGroupNamespaces(spec, 1<<22, "shared-ipc"); err == nil {
		t.Fatal("expected error for non-existent PID, got nil")
	}
}

func TestSharedSHMMount(t *testing.T) {
	m := SharedSHMMount("/run/wendy/shm/com.example.app")
	if m.Destination != "/dev/shm" {
		t.Errorf("Destination = %q, want /dev/shm", m.Destination)
	}
	if m.Type != "bind" {
		t.Errorf("Type = %q, want bind", m.Type)
	}
	if m.Source != "/run/wendy/shm/com.example.app" {
		t.Errorf("Source = %q, want /run/wendy/shm/com.example.app", m.Source)
	}
	found := false
	for _, opt := range m.Options {
		if opt == "rbind" {
			found = true
		}
	}
	if !found {
		t.Errorf("Options %v should contain 'rbind'", m.Options)
	}
}

func TestRemoveDefaultSHM(t *testing.T) {
	spec := DefaultSpec("rootfs", []string{"/bin/sh"})
	// Verify /dev/shm exists before removal.
	hasSHM := false
	for _, m := range spec.Mounts {
		if m.Destination == "/dev/shm" {
			hasSHM = true
		}
	}
	if !hasSHM {
		t.Skip("DefaultSpec does not include /dev/shm mount; skipping")
	}
	RemoveDefaultSHM(spec)
	for _, m := range spec.Mounts {
		if m.Destination == "/dev/shm" {
			t.Error("default /dev/shm should be removed after RemoveDefaultSHM")
		}
	}
}
