"""Greek search normalization. Port of GreekText.kt."""
import unicodedata

# Single-letter Greeklish -> Greek (phonetic-ish); digraphs not handled.
LATIN_TO_GREEK_ROUGH = {
    "a": "α", "b": "β", "c": "κ", "d": "δ", "e": "ε", "f": "φ",
    "g": "γ", "h": "η", "i": "ι", "j": "γ", "k": "κ", "l": "λ",
    "m": "μ", "n": "ν", "o": "ο", "p": "π", "q": "κ", "r": "ρ",
    "s": "σ", "t": "τ", "u": "υ", "v": "β", "w": "ω", "x": "ξ",
    "y": "υ", "z": "ζ",
}


def expand_latin_query(input_text):
    """Map Latin-only letter queries to a rough Greek form (Greeklish)."""
    text = (input_text or "").strip()
    if len(text) < 2:
        return input_text
    if not all(ch.isalpha() and ord(ch) < 0x80 for ch in text):
        return input_text
    return "".join(LATIN_TO_GREEK_ROUGH.get(ch.lower(), ch) for ch in text)


def normalize_greek(input_text):
    """Strip combining marks for fuzzy Greek match (SPEC section 10)."""
    nfd = unicodedata.normalize("NFD", (input_text or "").strip())
    return "".join(c for c in nfd if unicodedata.category(c) != "Mn").lower()


def stop_search_norm(stop_code, descr):
    return normalize_greek(" ".join(
        part for part in (stop_code, descr) if part and part.strip()))


def line_search_norm(line_id, line_code, descr):
    return normalize_greek(" ".join(
        part for part in (line_id, line_code, descr) if part and part.strip()))
