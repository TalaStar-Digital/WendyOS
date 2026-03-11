package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// PickerItem represents a selectable row in the device picker.
type PickerItem struct {
	// Display columns rendered in the table.
	Name        string
	Description string // optional secondary text rendered dimmed
	Type        string // "LAN", "Bluetooth", "External", etc.
	Address     string

	// DedupKey is used for deduplication. If empty, Name is used.
	// Items with the same DedupKey (case-insensitive) are merged via MergeItem.
	DedupKey string

	// Value is the opaque payload returned when this item is selected.
	Value interface{}
}

// PickerAddMsg adds new items to the picker. Duplicates (by Address) are ignored.
type PickerAddMsg struct {
	Items []PickerItem
}

// PickerDoneMsg signals that discovery has finished. The picker remains
// interactive so the user can still select from the collected items.
type PickerDoneMsg struct{}

// PickerModel is a Bubble Tea model that presents a live-updating list of
// items and lets the user select one with arrow keys + Enter.
type PickerModel struct {
	Title string // header line, e.g. "Select a device"

	// MergeItem is called when a new item shares a DedupKey with an existing
	// item. The caller can update existing in place (type, address, value, …).
	// If nil, duplicate items are silently dropped.
	MergeItem func(existing *PickerItem, incoming PickerItem)

	items    []PickerItem
	seenIdx  map[string]int // dedup key → index in items
	cursor   int
	selected *PickerItem
	scanning bool
	quitting bool
}

// NewPicker creates a new picker model with the default "Select a device" title.
func NewPicker() PickerModel {
	return PickerModel{
		Title:    "Select a device",
		seenIdx:  make(map[string]int),
		scanning: true,
	}
}

// NewPickerWithTitle creates a new picker model with a custom title.
func NewPickerWithTitle(title string) PickerModel {
	return PickerModel{
		Title:    title,
		seenIdx:  make(map[string]int),
		scanning: true,
	}
}

func (m PickerModel) Init() tea.Cmd { return nil }

func (m PickerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.items)-1 {
				m.cursor++
			}
		case "enter":
			if len(m.items) > 0 && m.cursor < len(m.items) {
				item := m.items[m.cursor]
				m.selected = &item
				return m, tea.Quit
			}
		case "q", "ctrl+c":
			m.quitting = true
			return m, tea.Quit
		}

	case PickerAddMsg:
		for _, item := range msg.Items {
			key := strings.ToLower(item.DedupKey)
			if key == "" {
				key = strings.ToLower(item.Name)
			}
			if idx, ok := m.seenIdx[key]; ok {
				if m.MergeItem != nil {
					m.MergeItem(&m.items[idx], item)
				}
				continue
			}
			m.seenIdx[key] = len(m.items)
			m.items = append(m.items, item)
		}

	case PickerDoneMsg:
		m.scanning = false
	}

	return m, nil
}

var (
	pickerTitle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205"))
	pickerHint     = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	pickerCursor   = lipgloss.NewStyle().Foreground(lipgloss.Color("229")).Bold(true)
	pickerNormal   = lipgloss.NewStyle()
	pickerScanning = lipgloss.NewStyle().Foreground(lipgloss.Color("205"))
)

func (m PickerModel) View() string {
	if m.quitting || m.selected != nil {
		return ""
	}

	var sb strings.Builder

	sb.WriteString(pickerTitle.Render(m.Title) + pickerHint.Render(" (↑/↓ navigate, enter select, q quit)") + "\n\n")

	if len(m.items) == 0 {
		if m.scanning {
			sb.WriteString(pickerScanning.Render("  Scanning for devices...") + "\n")
		} else {
			sb.WriteString(pickerHint.Render("  No devices found.") + "\n")
		}
		return sb.String()
	}

	// Render as a simple list with a cursor indicator.
	for i, item := range m.items {
		cursor := "  "
		style := pickerNormal
		if i == m.cursor {
			cursor = "> "
			style = pickerCursor
		}

		var line string
		if item.Type == "" && item.Address == "" {
			line = fmt.Sprintf("%s%s", cursor, item.Name)
		} else {
			line = fmt.Sprintf("%s%-24s %-16s %s", cursor, item.Name, item.Type, item.Address)
		}
		sb.WriteString(style.Render(line))
		if item.Description != "" {
			sb.WriteString(" " + pickerHint.Render(item.Description))
		}
		sb.WriteString("\n")
	}

	if m.scanning {
		sb.WriteString("\n" + pickerScanning.Render("  Scanning...") + "\n")
	}

	return sb.String()
}

// Cancelled returns true if the user quit the picker without selecting (e.g. Ctrl+C).
func (m PickerModel) Cancelled() bool {
	return m.quitting
}

// Selected returns the item the user chose, or nil if they quit without selecting.
func (m PickerModel) Selected() *PickerItem {
	return m.selected
}
