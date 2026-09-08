package documents

// This profile compares document trees, never flattened text. Unsupported
// content/attributes fail closed. It does not claim browser layout equivalence.
import (
	"bytes"
	"encoding/json"
	"io"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

const DocmostNativeProfile = "docmost.prosemirror.gfm.goldmark-1.8.6.v1"

type tree = map[string]any

type NativeComparison struct {
	SourceHash          string
	TargetHash          string
	PlatformHash        string
	PlatformDifferences int
}

func canonicalBytes(v any) []byte { b, _ := json.Marshal(v); return b }
func marksSorted(m []tree) []tree {
	r := append([]tree{}, m...)
	sort.Slice(r, func(i, j int) bool { return string(canonicalBytes(r[i])) < string(canonicalBytes(r[j])) })
	return r
}
func paragraph(children []tree) tree {
	return tree{"type": "paragraph", "indent": 0, "textAlign": nil, "children": children}
}
func coalesced(in []tree) []tree {
	out := []tree{}
	for _, n := range in {
		if len(out) > 0 && n["type"] == "text" && out[len(out)-1]["type"] == "text" && reflect.DeepEqual(n["marks"], out[len(out)-1]["marks"]) {
			out[len(out)-1]["text"] = out[len(out)-1]["text"].(string) + n["text"].(string)
		} else {
			out = append(out, n)
		}
	}
	return out
}
func sourceText(v []byte) string {
	return string(util.ResolveEntityNames(util.ResolveNumericReferences(util.UnescapePunctuations(v))))
}
func markdownTree(body string) (tree, error) {
	if !utf8.ValidString(body) {
		return nil, Failure("invalid_source_encoding")
	}
	if len(body) > 1_000_000 {
		return nil, Failure("native_source_too_large")
	}
	input := []byte(body)
	doc := goldmark.New(goldmark.WithExtensions(extension.GFM)).Parser().Parse(text.NewReader(input))
	count := 0
	var block func(ast.Node, int) (tree, error)
	var inline func(ast.Node, []tree, int) ([]tree, error)
	tick := func(depth int) error {
		count++
		if count > 50000 || depth > 128 {
			return Failure("native_complexity_limit")
		}
		return nil
	}
	inline = func(parent ast.Node, marks []tree, depth int) ([]tree, error) {
		out := []tree{}
		for n := parent.FirstChild(); n != nil; n = n.NextSibling() {
			if err := tick(depth); err != nil {
				return nil, err
			}
			txt := func(v string) { out = append(out, tree{"type": "text", "text": v, "marks": marksSorted(marks)}) }
			recurse := func(mark tree) error {
				m := append(append([]tree{}, marks...), mark)
				v, e := inline(n, m, depth+1)
				out = append(out, v...)
				return e
			}
			switch x := n.(type) {
			case *ast.Text:
				v := string(x.Value(input))
				if !x.IsRaw() {
					v = sourceText(x.Value(input))
				}
				txt(v)
				if x.HardLineBreak() {
					out = append(out, tree{"type": "hardBreak"})
				} else if x.SoftLineBreak() {
					txt("\n")
				}
			case *ast.String:
				v := string(x.Value)
				if !x.IsRaw() {
					v = sourceText(x.Value)
				}
				txt(v)
			case *ast.CodeSpan:
				var v strings.Builder
				for c := x.FirstChild(); c != nil; c = c.NextSibling() {
					t, ok := c.(*ast.Text)
					if !ok {
						return nil, Failure("unsupported_markdown")
					}
					v.WriteString(strings.ReplaceAll(string(t.Value(input)), "\n", " "))
				}
				out = append(out, tree{"type": "text", "text": v.String(), "marks": marksSorted(append(append([]tree{}, marks...), tree{"type": "code"}))})
			case *ast.Emphasis:
				kind := "italic"
				if x.Level == 2 {
					kind = "bold"
				}
				if err := recurse(tree{"type": kind}); err != nil {
					return nil, err
				}
			case *east.Strikethrough:
				if err := recurse(tree{"type": "strike"}); err != nil {
					return nil, err
				}
			case *ast.Link:
				var title any
				if len(x.Title) > 0 {
					title = sourceText(x.Title)
				}
				if err := recurse(tree{"type": "link", "href": sourceText(x.Destination), "title": title}); err != nil {
					return nil, err
				}
			default:
				return nil, Failure("unsupported_markdown")
			}
		}
		return coalesced(out), nil
	}
	block = func(n ast.Node, depth int) (tree, error) {
		if err := tick(depth); err != nil {
			return nil, err
		}
		result := tree{}
		children := []tree{}
		descend := true
		switch x := n.(type) {
		case *ast.Document:
			result["type"] = "doc"
		case *ast.Paragraph, *ast.TextBlock:
			v, e := inline(n, []tree{}, depth+1)
			if e != nil {
				return nil, e
			}
			return paragraph(v), nil
		case *ast.Heading:
			v, e := inline(n, []tree{}, depth+1)
			if e != nil {
				return nil, e
			}
			return tree{"type": "heading", "level": x.Level, "indent": 0, "textAlign": nil, "children": v}, nil
		case *ast.List:
			result["type"] = "bulletList"
			if x.IsOrdered() {
				result["type"] = "orderedList"
				result["start"] = x.Start
			}
		case *ast.ListItem:
			result["type"] = "listItem"
		case *east.Table:
			result["type"] = "table"
		case *east.TableHeader, *east.TableRow:
			result["type"] = "tableRow"
		case *east.TableCell:
			typ := "tableCell"
			if _, ok := n.Parent().(*east.TableHeader); ok {
				typ = "tableHeader"
			}
			var align any
			switch x.Alignment {
			case east.AlignLeft:
				align = "left"
			case east.AlignCenter:
				align = "center"
			case east.AlignRight:
				align = "right"
			}
			v, e := inline(n, []tree{}, depth+1)
			if e != nil {
				return nil, e
			}
			result = tree{"type": typ, "align": align, "colspan": 1, "rowspan": 1, "colwidth": nil, "backgroundColor": nil, "backgroundColorName": nil}
			children = []tree{paragraph(v)}
			descend = false
		default:
			return nil, Failure("unsupported_markdown")
		}
		if descend {
			for c := n.FirstChild(); c != nil; c = c.NextSibling() {
				v, e := block(c, depth+1)
				if e != nil {
					return nil, e
				}
				children = append(children, v)
			}
		}
		result["children"] = children
		return result, nil
	}
	return block(doc, 0)
}

// Decode with explicit duplicate-key rejection: a hidden second attrs/content
// key must not disappear before structural validation.
func strictJSON(raw []byte) (any, error) {
	if !utf8.Valid(raw) {
		return nil, Failure("invalid_native_encoding")
	}
	// encoding/json replaces malformed UTF-16 escapes with U+FFFD. Reject those
	// instead of accidentally equating a broken escape to a real replacement char.
	for i := 0; i < len(raw); i++ {
		if raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw) {
			return nil, Failure("invalid_native_document")
		}
		if raw[i] != 'u' {
			continue
		}
		if i+4 >= len(raw) {
			return nil, Failure("invalid_native_document")
		}
		v, e := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		if e != nil {
			return nil, Failure("invalid_native_document")
		}
		i += 4
		if v >= 0xd800 && v <= 0xdbff {
			if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return nil, Failure("invalid_native_encoding")
			}
			low, e := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
			if e != nil || low < 0xdc00 || low > 0xdfff {
				return nil, Failure("invalid_native_encoding")
			}
			i += 6
		} else if v >= 0xdc00 && v <= 0xdfff {
			return nil, Failure("invalid_native_encoding")
		}
	}

	if len(raw) > 2_000_000 {
		return nil, Failure("native_target_too_large")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	count := 0
	var read func(int) (any, error)
	read = func(depth int) (any, error) {
		count++
		if depth > 160 || count > 200000 {
			return nil, Failure("native_complexity_limit")
		}
		tok, e := d.Token()
		if e != nil {
			return nil, Failure("invalid_native_document")
		}
		delim, ok := tok.(json.Delim)
		if !ok {
			return tok, nil
		}
		switch delim {
		case '{':
			m := map[string]any{}
			for d.More() {
				k, e := d.Token()
				s, ok := k.(string)
				if e != nil || !ok {
					return nil, Failure("invalid_native_document")
				}
				if _, ok := m[s]; ok {
					return nil, Failure("invalid_native_document")
				}
				v, e := read(depth + 1)
				if e != nil {
					return nil, e
				}
				m[s] = v
			}
			end, e := d.Token()
			if e != nil || end != json.Delim('}') {
				return nil, Failure("invalid_native_document")
			}
			return m, nil
		case '[':
			a := []any{}
			for d.More() {
				v, e := read(depth + 1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
			end, e := d.Token()
			if e != nil || end != json.Delim(']') {
				return nil, Failure("invalid_native_document")
			}
			return a, nil
		default:
			return nil, Failure("invalid_native_document")
		}
	}
	v, e := read(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, Failure("invalid_native_document")
	}
	return v, nil
}

func docmostTree(raw []byte) (tree, []tree, error) {
	decoded, e := strictJSON(raw)
	if e != nil {
		return nil, nil, e
	}
	metadata := []tree{}
	count := 0
	var visit func(any, int) (tree, error)
	visit = func(value any, depth int) (tree, error) {
		count++
		if depth > 128 || count > 50000 {
			return nil, Failure("native_complexity_limit")
		}
		n, ok := value.(map[string]any)
		if !ok {
			return nil, Failure("invalid_native_document")
		}
		typ, ok := n["type"].(string)
		if !ok {
			return nil, Failure("invalid_native_document")
		}
		for k := range n {
			if k != "type" && k != "attrs" && k != "content" && k != "text" && k != "marks" {
				return nil, Failure("unsupported_native_document")
			}
		}
		attrs := map[string]any{}
		if a, exists := n["attrs"]; exists {
			var ok bool
			attrs, ok = a.(map[string]any)
			if !ok {
				return nil, Failure("invalid_native_document")
			}
		}
		used := map[string]bool{}
		take := func(k string, defaultValue any) any {
			used[k] = true
			if attrs[k] != nil {
				return attrs[k]
			}
			return defaultValue
		}
		children := []tree{}
		if c, exists := n["content"]; exists {
			list, ok := c.([]any)
			if !ok {
				return nil, Failure("invalid_native_document")
			}
			for _, v := range list {
				x, e := visit(v, depth+1)
				if e != nil {
					return nil, e
				}
				children = append(children, x)
			}
		}
		r := tree{"type": typ}
		switch typ {
		case "doc", "bulletList", "listItem", "table", "tableRow":
			r["children"] = children
		case "orderedList":
			r["start"] = take("start", 1)
			r["children"] = children
		case "heading", "paragraph":
			r["indent"] = take("indent", 0)
			r["textAlign"] = take("textAlign", nil)
			r["children"] = coalesced(children)
			if typ == "heading" {
				r["level"] = take("level", 1)
			}
		case "tableHeader", "tableCell":
			for _, k := range []string{"align", "colwidth", "backgroundColor", "backgroundColorName"} {
				r[k] = take(k, nil)
			}
			r["colspan"] = take("colspan", 1)
			r["rowspan"] = take("rowspan", 1)
			r["children"] = children
		case "text":
			text, ok := n["text"].(string)
			if !ok || len(children) > 0 {
				return nil, Failure("invalid_native_document")
			}
			marks := []tree{}
			if value, exists := n["marks"]; exists {
				list, ok := value.([]any)
				if !ok {
					return nil, Failure("invalid_native_document")
				}
				for _, value := range list {
					m, ok := value.(map[string]any)
					if !ok {
						return nil, Failure("invalid_native_document")
					}
					for k := range m {
						if k != "type" && k != "attrs" {
							return nil, Failure("unsupported_native_document")
						}
					}
					kind, ok := m["type"].(string)
					if !ok {
						return nil, Failure("invalid_native_document")
					}
					a := map[string]any{}
					if x, exists := m["attrs"]; exists {
						var ok bool
						a, ok = x.(map[string]any)
						if !ok {
							return nil, Failure("invalid_native_document")
						}
					}
					switch kind {
					case "bold", "code", "italic", "strike":
						if len(a) != 0 {
							return nil, Failure("unsupported_native_document")
						}
						marks = append(marks, tree{"type": kind})
					case "link":
						for k := range a {
							if k != "href" && k != "title" && k != "target" && k != "rel" && k != "class" && k != "internal" {
								return nil, Failure("unsupported_native_document")
							}
						}
						href, ok := a["href"].(string)
						if !ok {
							return nil, Failure("invalid_native_document")
						}
						title := a["title"]
						if title != nil {
							if _, ok := title.(string); !ok {
								return nil, Failure("invalid_native_document")
							}
						}
						behavior := tree{"target": a["target"], "rel": a["rel"], "class": a["class"], "internal": a["internal"]}
						// Explicitly permitted provider defaults; any new behavior needs a new
						// reviewed profile. Still hash and count these differences in receipts.
						if behavior["target"] != nil && behavior["target"] != "_blank" || behavior["rel"] != nil && behavior["rel"] != "noopener noreferrer nofollow" || behavior["class"] != nil || behavior["internal"] != nil && behavior["internal"] != false {
							return nil, Failure("unsupported_native_link_behavior")
						}
						metadata = append(metadata, behavior)
						marks = append(marks, tree{"type": "link", "href": href, "title": title})
					default:
						return nil, Failure("unsupported_native_document")
					}
				}
			}
			r["text"] = text
			r["marks"] = marksSorted(marks)
		case "hardBreak":
			if len(children) != 0 {
				return nil, Failure("invalid_native_document")
			}
		default:
			return nil, Failure("unsupported_native_document")
		}
		if typ != "text" {
			if _, ok := n["text"]; ok {
				return nil, Failure("unsupported_native_document")
			}
			if value, ok := n["marks"]; ok {
				a, valid := value.([]any)
				if !valid || len(a) != 0 {
					return nil, Failure("unsupported_native_document")
				}
			}
		}
		if _, ok := attrs["id"]; ok {
			used["id"] = true
			if id, ok := attrs["id"].(string); !ok || id == "" {
				return nil, Failure("invalid_native_document")
			}
		}
		for k := range attrs {
			if !used[k] {
				return nil, Failure("unsupported_native_document")
			}
		}
		return r, nil
	}
	v, e := visit(decoded, 0)
	if e != nil {
		return nil, nil, e
	}
	if v["type"] != "doc" {
		return nil, nil, Failure("invalid_native_document")
	}
	return v, metadata, nil
}

func CompareDocmostNative(source string, native json.RawMessage) (NativeComparison, error) {
	var proof NativeComparison
	s, e := markdownTree(source)
	if e != nil {
		return proof, e
	}
	t, platform, e := docmostTree(native)
	if e != nil {
		return proof, e
	}
	proof.SourceHash = Hash(string(canonicalBytes(s)))
	proof.TargetHash = Hash(string(canonicalBytes(t)))
	proof.PlatformHash = Hash(string(canonicalBytes(platform)))
	for _, m := range platform {
		for _, v := range m {
			if v != nil {
				proof.PlatformDifferences++
			}
		}
	}
	if proof.SourceHash != proof.TargetHash {
		return proof, Failure("native_structure_mismatch")
	}
	return proof, nil
}
