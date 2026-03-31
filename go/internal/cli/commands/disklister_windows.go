//go:build windows

package commands

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"

	"github.com/dustin/go-humanize"
)

// Windows IOCTL codes for volume management.
const (
	fsctlLockVolume          = 0x00090018
	fsctlDismountVolume      = 0x00090020
	fsctlAllowExtendedDASDIO = 0x00090083
	ioctlDiskGetDriveLayout  = 0x00070050
)

// drive represents an external disk suitable for image writing.
type drive struct {
	DevicePath  string // e.g. \\.\PhysicalDrive1
	RawPath     string // same as DevicePath on Windows
	Name        string // human-readable name
	Size        string // human-readable size
	SizeBytes   int64  // size in bytes
	IsRemovable bool
}

// psDisk is the JSON structure returned by the joined Get-Disk / Get-PhysicalDisk query.
type psDisk struct {
	Number       int    `json:"Number"`
	FriendlyName string `json:"FriendlyName"`
	Size         int64  `json:"Size"`
	BusType      string `json:"BusType"`
	IsSystem     bool   `json:"IsSystem"`
	IsReadOnly   bool   `json:"IsReadOnly"`
	MediaType    string `json:"MediaType"`
}

// listAllDrives lists all physical drives on Windows using PowerShell Get-Disk.
func listAllDrives() ([]drive, error) {
	return listDrivesWindows(false)
}

// listExternalDrives lists removable/USB physical drives on Windows.
func listExternalDrives() ([]drive, error) {
	return listDrivesWindows(true)
}

func listDrivesWindows(externalOnly bool) ([]drive, error) {
	// Join Get-Disk with Get-PhysicalDisk to get both logical and physical
	// properties (BusType, IsSystem from Get-Disk; MediaType from Get-PhysicalDisk).
	script := "Get-Disk | ForEach-Object { " +
		"$pd = Get-PhysicalDisk -DeviceNumber $_.Number -ErrorAction SilentlyContinue; " +
		"$mt = if ($pd) { $pd.MediaType } else { 'Unspecified' }; " +
		"[PSCustomObject]@{ Number=$_.Number; FriendlyName=$_.FriendlyName; Size=$_.Size; " +
		"BusType=$_.BusType; IsSystem=$_.IsSystem; IsReadOnly=$_.IsReadOnly; MediaType=$mt } " +
		"} | ConvertTo-Json -Compress"
	out, err := exec.Command("powershell", "-NoProfile", "-Command", script).Output()
	if err != nil {
		return nil, fmt.Errorf("running Get-Disk: %w", err)
	}

	outStr := strings.TrimSpace(string(out))
	if outStr == "" {
		return nil, nil
	}

	// PowerShell returns a single object (not array) when there's only one disk.
	var disks []psDisk
	if strings.HasPrefix(outStr, "[") {
		if err := json.Unmarshal([]byte(outStr), &disks); err != nil {
			return nil, fmt.Errorf("parsing Get-Disk output: %w", err)
		}
	} else {
		var single psDisk
		if err := json.Unmarshal([]byte(outStr), &single); err != nil {
			return nil, fmt.Errorf("parsing Get-Disk output: %w", err)
		}
		disks = []psDisk{single}
	}

	var drives []drive
	for _, d := range disks {
		if d.IsReadOnly {
			continue
		}

		isExternal := isExternalBus(d.BusType) || !d.IsSystem
		if externalOnly {
			// Never include the system disk.
			if d.IsSystem {
				continue
			}
			// Include drives on external bus types (USB, SD, MMC), or
			// non-system drives that are not fixed SSDs/HDDs (catches
			// built-in PCIE card readers which report as SCSI).
			if !isExternalBus(d.BusType) && isFixedMedia(d.MediaType) {
				continue
			}
		}

		devPath := fmt.Sprintf(`\\.\PhysicalDrive%d`, d.Number)
		drives = append(drives, drive{
			DevicePath:  devPath,
			RawPath:     devPath,
			Name:        d.FriendlyName,
			Size:        humanize.Bytes(uint64(d.Size)),
			SizeBytes:   d.Size,
			IsRemovable: isExternal,
		})
	}

	return drives, nil
}

// isExternalBus returns true for bus types that indicate a removable/external drive.
func isExternalBus(busType string) bool {
	switch strings.ToUpper(busType) {
	case "USB", "SD", "MMC":
		return true
	default:
		return false
	}
}

// isFixedMedia returns true for media types that are permanently installed
// (SSD, HDD). Returns false for unspecified/removable media (SD cards in
// built-in readers, USB sticks) which often report as "Unspecified".
func isFixedMedia(mediaType string) bool {
	switch strings.ToUpper(mediaType) {
	case "SSD", "HDD":
		return true
	default:
		return false
	}
}

// getVolumesForDisk returns the drive letters (e.g. ["E", "F"]) for volumes
// on a given physical disk number.
func getVolumesForDisk(diskNumber int) ([]string, error) {
	script := fmt.Sprintf(
		"Get-Partition -DiskNumber %d -ErrorAction SilentlyContinue | "+
			"Where-Object { $_.DriveLetter } | "+
			"Select-Object -ExpandProperty DriveLetter",
		diskNumber,
	)
	out, err := exec.Command("powershell", "-NoProfile", "-Command", script).Output()
	if err != nil {
		return nil, nil // no partitions is fine
	}
	var letters []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		l := strings.TrimSpace(line)
		if len(l) > 0 {
			letters = append(letters, l[:1])
		}
	}
	return letters, nil
}

// lockAndDismountVolume opens a volume by drive letter, locks it with
// FSCTL_LOCK_VOLUME, then dismounts it with FSCTL_DISMOUNT_VOLUME.
// Returns the volume handle which must be kept open until writing is complete.
func lockAndDismountVolume(letter string) (syscall.Handle, error) {
	volPath := `\\.\` + letter + ":"
	pathUTF16, err := syscall.UTF16PtrFromString(volPath)
	if err != nil {
		return syscall.InvalidHandle, err
	}

	h, err := syscall.CreateFile(
		pathUTF16,
		syscall.GENERIC_READ|syscall.GENERIC_WRITE,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE,
		nil,
		syscall.OPEN_EXISTING,
		syscall.FILE_ATTRIBUTE_NORMAL,
		0,
	)
	if err != nil {
		return syscall.InvalidHandle, fmt.Errorf("opening volume %s: %w", volPath, err)
	}

	var bytesReturned uint32

	// Lock the volume to get exclusive access.
	err = syscall.DeviceIoControl(h, fsctlLockVolume, nil, 0, nil, 0, &bytesReturned, nil)
	if err != nil {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, fmt.Errorf("locking volume %s: %w", volPath, err)
	}

	// Dismount the volume's filesystem.
	err = syscall.DeviceIoControl(h, fsctlDismountVolume, nil, 0, nil, 0, &bytesReturned, nil)
	if err != nil {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, fmt.Errorf("dismounting volume %s: %w", volPath, err)
	}

	return h, nil
}

// parseDiskNumber extracts the disk number from a \\.\PhysicalDriveN path.
func parseDiskNumber(devPath string) (int, error) {
	var n int
	_, err := fmt.Sscanf(devPath, `\\.\PhysicalDrive%d`, &n)
	if err != nil {
		return 0, fmt.Errorf("parsing disk number from %q: %w", devPath, err)
	}
	return n, nil
}

// writeImageToDisk writes an image file to a physical drive on Windows.
// It locks and dismounts all volumes on the disk, opens the raw physical
// device, and writes in 4 MiB chunks with sector-aligned I/O.
func writeImageToDisk(imagePath string, d drive, progressFn func(written int64)) error {
	diskNum, err := parseDiskNumber(d.DevicePath)
	if err != nil {
		return err
	}

	// Lock and dismount every volume on this disk. We must keep the volume
	// handles open for the entire duration of the write — closing them would
	// release the lock and let Windows re-mount the filesystem.
	letters, err := getVolumesForDisk(diskNum)
	if err != nil {
		return fmt.Errorf("enumerating volumes: %w", err)
	}

	var volumeHandles []syscall.Handle
	defer func() {
		for _, h := range volumeHandles {
			syscall.CloseHandle(h)
		}
	}()

	for _, letter := range letters {
		h, err := lockAndDismountVolume(letter)
		if err != nil {
			return fmt.Errorf("preparing volume %s: %w", letter, err)
		}
		volumeHandles = append(volumeHandles, h)
	}

	imgFile, err := os.Open(imagePath)
	if err != nil {
		return fmt.Errorf("opening image: %w", err)
	}
	defer imgFile.Close()

	// Open the raw physical drive for writing.
	devPathUTF16, err := syscall.UTF16PtrFromString(d.DevicePath)
	if err != nil {
		return fmt.Errorf("encoding device path: %w", err)
	}

	handle, err := syscall.CreateFile(
		devPathUTF16,
		syscall.GENERIC_READ|syscall.GENERIC_WRITE,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE,
		nil,
		syscall.OPEN_EXISTING,
		syscall.FILE_ATTRIBUTE_NORMAL|0x80000000, // FILE_FLAG_WRITE_THROUGH
		0,
	)
	if err != nil {
		return fmt.Errorf("opening %s for writing (are you running as Administrator?): %w", d.DevicePath, err)
	}
	defer syscall.CloseHandle(handle)

	// Allow writes beyond the reported partition layout. Without this,
	// Windows may reject writes that extend past existing partitions.
	var bytesReturned uint32
	_ = syscall.DeviceIoControl(handle, fsctlAllowExtendedDASDIO, nil, 0, nil, 0, &bytesReturned, nil)

	// Lock the physical drive itself for exclusive access.
	_ = syscall.DeviceIoControl(handle, fsctlLockVolume, nil, 0, nil, 0, &bytesReturned, nil)

	diskFile := os.NewFile(uintptr(handle), d.DevicePath)

	buf := make([]byte, 4*1024*1024) // 4 MiB
	var totalWritten int64
	for {
		n, readErr := imgFile.Read(buf)
		if n > 0 {
			// Writes to raw disks on Windows must be sector-aligned.
			// Pad the final chunk to a 512-byte boundary.
			writeLen := n
			if remainder := n % 512; remainder != 0 {
				writeLen = n + (512 - remainder)
				// Zero-fill the padding bytes.
				for i := n; i < writeLen; i++ {
					buf[i] = 0
				}
			}
			if _, writeErr := diskFile.Write(buf[:writeLen]); writeErr != nil {
				return fmt.Errorf("writing to disk: %w", writeErr)
			}
			totalWritten += int64(n)
			if progressFn != nil {
				progressFn(totalWritten)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("reading image: %w", readErr)
		}
	}

	// Flush the file buffers.
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	flushFileBuffers := kernel32.NewProc("FlushFileBuffers")
	flushFileBuffers.Call(uintptr(handle)) //nolint:errcheck

	// Suppress unused import warning — unsafe is needed for DeviceIoControl pointer args.
	_ = unsafe.Sizeof(0)

	return nil
}
