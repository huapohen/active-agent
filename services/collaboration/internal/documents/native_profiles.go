package documents

const DocmostCodeNativeProfile = "docmost.prosemirror.gfm-code.goldmark-1.8.6.v2"
const AffineCodeNativeProfile = "affine.database-v3.code-v1.rich-text.b4c8548c0.v2"

func nativeProfileProvider(profile string) string {
	switch profile {
	case DocmostNativeProfile, DocmostCodeNativeProfile:
		return "docmost"
	case AffineNativeProfile, AffineCodeNativeProfile:
		return "affine"
	default:
		return ""
	}
}

func codeProfile(profile string) bool {
	return profile == DocmostCodeNativeProfile || profile == AffineCodeNativeProfile
}

func markdownTreeForProfile(body, profile string) (tree, error) {
	if nativeProfileProvider(profile) == "" {
		return nil, Failure("unsupported_native_profile")
	}
	return markdownTreeVersion(body, codeProfile(profile))
}

// Code languages are literal identifiers, never arbitrary metadata or a URL.
// Empty/absent language is distinct from an explicitly named language.
func codeLanguage(value string) bool {
	if len(value) > 80 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.' || c == '+' || c == '#') {
			return false
		}
	}
	return true
}
