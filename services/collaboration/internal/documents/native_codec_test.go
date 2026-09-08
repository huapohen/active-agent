package documents

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func nativeFixture(t *testing.T) (string, []byte) {
	t.Helper()
	s, e := os.ReadFile("testdata/native/delivery.md")
	if e != nil {
		t.Fatal(e)
	}
	n, e := os.ReadFile("testdata/native/docmost.json")
	if e != nil {
		t.Fatal(e)
	}
	return string(s), n
}
func TestDocmostNativeFullPublishedFixtureAndIndependentMarkedTree(t *testing.T) {
	s, n := nativeFixture(t)
	p, e := CompareDocmostNative(s, n)
	if e != nil {
		t.Fatal(e)
	}
	if p.SourceHash != p.TargetHash || p.PlatformDifferences != 27 {
		t.Fatalf("proof %+v", p)
	}
	expectedRaw, e := os.ReadFile("testdata/native/marked-source.json")
	if e != nil {
		t.Fatal(e)
	}
	var expected, actual any
	json.Unmarshal(expectedRaw, &expected)
	tree, e := markdownTree(s)
	if e != nil {
		t.Fatal(e)
	}
	json.Unmarshal(canonicalBytes(tree), &actual)
	if !reflect.DeepEqual(actual, expected) {
		t.Fatal("Goldmark tree differs from independent frozen marked 18.0.11 tree")
	}
}
func mutateNative(t *testing.T, raw []byte, pred func(map[string]any) bool, change func(map[string]any)) []byte {
	t.Helper()
	var n any
	if e := json.Unmarshal(raw, &n); e != nil {
		t.Fatal(e)
	}
	var walk func(any) bool
	walk = func(v any) bool {
		switch x := v.(type) {
		case map[string]any:
			if pred(x) {
				change(x)
				return true
			}
			for _, v := range x {
				if walk(v) {
					return true
				}
			}
		case []any:
			for _, v := range x {
				if walk(v) {
					return true
				}
			}
		}
		return false
	}
	if !walk(n) {
		t.Fatal("mutation target missing")
	}
	return canonicalBytes(n)
}
func TestDocmostNativeRejectsStructuralAndFormatMutations(t *testing.T) {
	s, n := nativeFixture(t)
	tests := []struct {
		name   string
		pred   func(map[string]any) bool
		change func(map[string]any)
	}{
		{"heading", func(n map[string]any) bool { return n["type"] == "heading" }, func(n map[string]any) { n["attrs"].(map[string]any)["level"] = 6 }},
		{"header", func(n map[string]any) bool { return n["type"] == "tableHeader" }, func(n map[string]any) { n["type"] = "tableCell" }},
		{"table_order", func(n map[string]any) bool { return n["type"] == "tableRow" }, func(n map[string]any) { c := n["content"].([]any); c[0], c[1] = c[1], c[0] }},
		{"text", func(n map[string]any) bool { return n["type"] == "text" }, func(n map[string]any) { n["text"] = n["text"].(string) + " " }},
		{"code", func(n map[string]any) bool { return n["type"] == "code" }, func(n map[string]any) { n["type"] = "italic" }},
		{"bold", func(n map[string]any) bool { return n["type"] == "bold" }, func(n map[string]any) { n["type"] = "italic" }},
		{"link", func(n map[string]any) bool { return n["type"] == "link" }, func(n map[string]any) { n["attrs"].(map[string]any)["href"] = "https://example.test/changed" }},
		{"unknown_attribute", func(n map[string]any) bool { return n["type"] == "paragraph" }, func(n map[string]any) { n["attrs"].(map[string]any)["unreviewed"] = true }},
		{"link_behavior", func(n map[string]any) bool { return n["type"] == "link" }, func(n map[string]any) { n["attrs"].(map[string]any)["target"] = "_self" }},
		{"list_ancestry", func(n map[string]any) bool { return n["type"] == "listItem" }, func(n map[string]any) { n["type"] = "bulletList" }},
		{"extra_header_row", func(n map[string]any) bool { return n["type"] == "table" }, func(n map[string]any) {
			c := n["content"].([]any)
			n["content"] = append([]any{map[string]any{"type": "tableRow", "content": []any{}}}, c...)
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw := mutateNative(t, n, tt.pred, tt.change)
			if _, e := CompareDocmostNative(s, raw); e == nil {
				t.Fatal("accepted native mutation")
			}
		})
	}
}
func TestDocmostNativeRejectsUnsupportedAndAmbiguousInput(t *testing.T) {
	for _, s := range []string{"![image](x)", "<script>x</script>", "- [x] task", "```go\nx\n```"} {
		if _, e := markdownTree(s); e == nil {
			t.Fatalf("accepted unsupported %q", s)
		}
	}
	for _, s := range []string{`{"type":"doc","type":"doc","content":[]}`, `{"type":"doc","content":[]} {}`, `{"type":"doc","content":[{"type":"mystery"}]}`} {
		if _, _, e := docmostTree([]byte(s)); e == nil {
			t.Fatal("accepted invalid/unsupported native")
		}
	}
	if _, e := markdownTree(strings.Repeat("x", 1_000_001)); e == nil {
		t.Fatal("unbounded source")
	}
}

func TestNativeUnicodeEscapesAreExact(t *testing.T) {
	valid := []byte(`{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"\ud83d\ude00"}]}]}`)
	if _, e := CompareDocmostNative("😀", valid); e != nil {
		t.Fatal(e)
	}
	invalid := []byte(`{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"\ud800"}]}]}`)
	if _, e := CompareDocmostNative("�", invalid); e == nil {
		t.Fatal("invalid surrogate collapsed to replacement char")
	}
}
