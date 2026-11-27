//! Pure-Rust Thompson NFA regular expression matcher with zero external crates.
//!
//! Designed for server-name and domain filters:
//! - Linear-time `O(N * M)` matching without backtracking (immune to ReDoS).
//! - Full Unicode character awareness (flags, symbols, Cyrillic).
//! - Case-insensitive by default to match Tachyon filter UI conventions, with
//!   support for `(?-i)` / `(?i)` prefix overrides and `/pattern/flags` wrappers.

const MAX_AST_DEPTH: usize = 64;
const MAX_REPEAT_COUNT: usize = 64;
const MAX_NFA_STATES: usize = 2048;
const UNSET: usize = usize::MAX;

#[derive(Clone, Copy, PartialEq, Eq)]
enum AssertKind {
    Start,
    End,
    WordBoundary,
    NotWordBoundary,
}

#[derive(Clone, Copy)]
enum PredefinedClass {
    Digit,
    NonDigit,
    Word,
    NonWord,
    Space,
    NonSpace,
}

#[derive(Clone)]
enum ClassItem {
    Single(char),
    Range(char, char),
    Predefined(PredefinedClass),
}

#[derive(Clone)]
enum CharMatcher {
    Any,
    Exact(char),
    Predefined(PredefinedClass),
    Class {
        negated: bool,
        items: Vec<ClassItem>,
    },
}

impl CharMatcher {
    fn matches(&self, ch: char, case_insensitive: bool) -> bool {
        match self {
            Self::Any => ch != '\n' && ch != '\r',
            Self::Exact(target) => char_eq(ch, *target, case_insensitive),
            Self::Predefined(kind) => matches_predefined(*kind, ch),
            Self::Class { negated, items } => {
                let hit = items
                    .iter()
                    .any(|item| matches_class_item(item, ch, case_insensitive));
                if *negated { !hit } else { hit }
            }
        }
    }
}

fn char_eq(a: char, b: char, case_insensitive: bool) -> bool {
    if a == b {
        return true;
    }
    if !case_insensitive {
        return false;
    }
    if a.is_ascii() && b.is_ascii() {
        return a.eq_ignore_ascii_case(&b);
    }
    a.to_lowercase().eq(b.to_lowercase())
}

fn char_in_range(ch: char, lo: char, hi: char, case_insensitive: bool) -> bool {
    if (lo..=hi).contains(&ch) {
        return true;
    }
    if !case_insensitive {
        return false;
    }
    ch.to_lowercase().any(|c| (lo..=hi).contains(&c))
        || ch.to_uppercase().any(|c| (lo..=hi).contains(&c))
}

fn matches_predefined(kind: PredefinedClass, ch: char) -> bool {
    match kind {
        PredefinedClass::Digit => ch.is_ascii_digit(),
        PredefinedClass::NonDigit => !ch.is_ascii_digit(),
        PredefinedClass::Word => is_word_char(ch),
        PredefinedClass::NonWord => !is_word_char(ch),
        PredefinedClass::Space => ch.is_whitespace(),
        PredefinedClass::NonSpace => !ch.is_whitespace(),
    }
}

fn matches_class_item(item: &ClassItem, ch: char, case_insensitive: bool) -> bool {
    match item {
        ClassItem::Single(target) => char_eq(ch, *target, case_insensitive),
        ClassItem::Range(lo, hi) => char_in_range(ch, *lo, *hi, case_insensitive),
        ClassItem::Predefined(kind) => matches_predefined(*kind, ch),
    }
}

fn is_word_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

enum Ast {
    Empty,
    Matcher(CharMatcher),
    Assert(AssertKind),
    Concat(Vec<Ast>),
    Alt(Vec<Ast>),
    Repeat {
        inner: Box<Ast>,
        min: usize,
        max: Option<usize>,
    },
}

struct Parser<'a> {
    chars: &'a [char],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.chars.get(self.pos).copied()?;
        self.pos += 1;
        Some(ch)
    }

    fn parse_alt(&mut self, depth: usize) -> Result<Ast, ()> {
        if depth > MAX_AST_DEPTH {
            return Err(());
        }
        let mut branches = vec![self.parse_concat(depth)?];
        while self.peek() == Some('|') {
            self.pos += 1;
            branches.push(self.parse_concat(depth)?);
        }
        if branches.len() == 1 {
            Ok(branches.pop().unwrap_or(Ast::Empty))
        } else {
            Ok(Ast::Alt(branches))
        }
    }

    fn parse_concat(&mut self, depth: usize) -> Result<Ast, ()> {
        let mut items = Vec::new();
        while let Some(ch) = self.peek() {
            if ch == '|' || ch == ')' {
                break;
            }
            items.push(self.parse_quantified(depth)?);
        }
        if items.is_empty() {
            Ok(Ast::Empty)
        } else if items.len() == 1 {
            Ok(items.pop().unwrap_or(Ast::Empty))
        } else {
            Ok(Ast::Concat(items))
        }
    }

    fn parse_quantified(&mut self, depth: usize) -> Result<Ast, ()> {
        let mut atom = self.parse_atom(depth)?;
        if let Some((min, max)) = self.try_parse_quantifier()? {
            if matches!(atom, Ast::Empty | Ast::Assert(_)) {
                return Err(());
            }
            if self.peek() == Some('?') {
                self.pos += 1;
            }
            if matches!(self.peek(), Some('*' | '+' | '?' | '{')) && self.is_quantifier_ahead() {
                return Err(());
            }
            atom = Ast::Repeat {
                inner: Box::new(atom),
                min,
                max,
            };
        }
        Ok(atom)
    }

    fn is_quantifier_ahead(&self) -> bool {
        match self.peek() {
            Some('*' | '+' | '?') => true,
            Some('{') => {
                let mut probe = Parser {
                    chars: self.chars,
                    pos: self.pos,
                };
                probe.try_parse_braced_quantifier().is_ok()
            }
            _ => false,
        }
    }

    fn try_parse_quantifier(&mut self) -> Result<Option<(usize, Option<usize>)>, ()> {
        match self.peek() {
            Some('*') => {
                self.pos += 1;
                Ok(Some((0, None)))
            }
            Some('+') => {
                self.pos += 1;
                Ok(Some((1, None)))
            }
            Some('?') => {
                self.pos += 1;
                Ok(Some((0, Some(1))))
            }
            Some('{') => self.try_parse_braced_quantifier().map(Some),
            _ => Ok(None),
        }
    }

    fn try_parse_braced_quantifier(&mut self) -> Result<(usize, Option<usize>), ()> {
        if self.next() != Some('{') {
            return Err(());
        }
        let min = self.parse_usize_digits()?;
        if min > MAX_REPEAT_COUNT {
            return Err(());
        }
        match self.next() {
            Some('}') => Ok((min, Some(min))),
            Some(',') => {
                if self.peek() == Some('}') {
                    self.pos += 1;
                    return Ok((min, None));
                }
                let max = self.parse_usize_digits()?;
                if max > MAX_REPEAT_COUNT || max < min || self.next() != Some('}') {
                    return Err(());
                }
                Ok((min, Some(max)))
            }
            _ => Err(()),
        }
    }

    fn parse_usize_digits(&mut self) -> Result<usize, ()> {
        let mut val = 0usize;
        let mut has_digit = false;
        while let Some(ch) = self.peek() {
            if let Some(d) = ch.to_digit(10) {
                has_digit = true;
                val = val.saturating_mul(10).saturating_add(d as usize);
                if val > MAX_REPEAT_COUNT + 1 {
                    return Err(());
                }
                self.pos += 1;
            } else {
                break;
            }
        }
        if has_digit { Ok(val) } else { Err(()) }
    }

    fn parse_atom(&mut self, depth: usize) -> Result<Ast, ()> {
        let ch = self.next().ok_or(())?;
        match ch {
            '(' => {
                if self.peek() == Some('?') {
                    self.pos += 1;
                    if self.next() != Some(':') {
                        return Err(());
                    }
                }
                let inner = self.parse_alt(depth + 1)?;
                if self.next() != Some(')') {
                    return Err(());
                }
                Ok(inner)
            }
            ')' | '*' | '+' | '?' | '{' | '}' => Err(()),
            '^' => Ok(Ast::Assert(AssertKind::Start)),
            '$' => Ok(Ast::Assert(AssertKind::End)),
            '.' => Ok(Ast::Matcher(CharMatcher::Any)),
            '[' => self.parse_char_class(),
            '\\' => self.parse_escape_atom(),
            literal => Ok(Ast::Matcher(CharMatcher::Exact(literal))),
        }
    }

    fn parse_escape_atom(&mut self) -> Result<Ast, ()> {
        let esc = self.next().ok_or(())?;
        match esc {
            'b' => Ok(Ast::Assert(AssertKind::WordBoundary)),
            'B' => Ok(Ast::Assert(AssertKind::NotWordBoundary)),
            'd' => Ok(Ast::Matcher(CharMatcher::Predefined(
                PredefinedClass::Digit,
            ))),
            'D' => Ok(Ast::Matcher(CharMatcher::Predefined(
                PredefinedClass::NonDigit,
            ))),
            'w' => Ok(Ast::Matcher(CharMatcher::Predefined(PredefinedClass::Word))),
            'W' => Ok(Ast::Matcher(CharMatcher::Predefined(
                PredefinedClass::NonWord,
            ))),
            's' => Ok(Ast::Matcher(CharMatcher::Predefined(
                PredefinedClass::Space,
            ))),
            'S' => Ok(Ast::Matcher(CharMatcher::Predefined(
                PredefinedClass::NonSpace,
            ))),
            'n' => Ok(Ast::Matcher(CharMatcher::Exact('\n'))),
            'r' => Ok(Ast::Matcher(CharMatcher::Exact('\r'))),
            't' => Ok(Ast::Matcher(CharMatcher::Exact('\t'))),
            c if c.is_ascii_digit() || matches!(c, 'k' | 'p' | 'P' | 'c') => Err(()),
            literal => Ok(Ast::Matcher(CharMatcher::Exact(literal))),
        }
    }

    fn parse_class_escape(&mut self) -> Result<ClassItem, ()> {
        let esc = self.next().ok_or(())?;
        match esc {
            'd' => Ok(ClassItem::Predefined(PredefinedClass::Digit)),
            'D' => Ok(ClassItem::Predefined(PredefinedClass::NonDigit)),
            'w' => Ok(ClassItem::Predefined(PredefinedClass::Word)),
            'W' => Ok(ClassItem::Predefined(PredefinedClass::NonWord)),
            's' => Ok(ClassItem::Predefined(PredefinedClass::Space)),
            'S' => Ok(ClassItem::Predefined(PredefinedClass::NonSpace)),
            'n' => Ok(ClassItem::Single('\n')),
            'r' => Ok(ClassItem::Single('\r')),
            't' => Ok(ClassItem::Single('\t')),
            'p' | 'P' | 'k' | 'c' => Err(()),
            literal => Ok(ClassItem::Single(literal)),
        }
    }

    fn parse_char_class(&mut self) -> Result<Ast, ()> {
        let mut negated = false;
        if self.peek() == Some('^') {
            negated = true;
            self.pos += 1;
        }
        let mut items = Vec::new();
        let mut closed = false;
        while let Some(ch) = self.next() {
            if ch == ']' {
                closed = true;
                break;
            }
            let first = if ch == '\\' {
                self.parse_class_escape()?
            } else {
                ClassItem::Single(ch)
            };

            if self.peek() == Some('-') && self.chars.get(self.pos + 1).copied() != Some(']') {
                self.pos += 1;
                let end_raw = self.next().ok_or(())?;
                let second = if end_raw == '\\' {
                    self.parse_class_escape()?
                } else {
                    ClassItem::Single(end_raw)
                };
                match (first, second) {
                    (ClassItem::Single(lo), ClassItem::Single(hi)) if lo <= hi => {
                        items.push(ClassItem::Range(lo, hi));
                    }
                    _ => return Err(()),
                }
            } else {
                items.push(first);
            }
        }
        if !closed {
            return Err(());
        }
        Ok(Ast::Matcher(CharMatcher::Class { negated, items }))
    }
}

#[derive(Clone)]
enum State {
    Match,
    Jump(usize),
    Split(usize, usize),
    Assert(AssertKind, usize),
    Step(CharMatcher, usize),
}

struct Fragment {
    start: usize,
    end: usize,
}

struct NfaBuilder {
    states: Vec<State>,
}

impl NfaBuilder {
    fn new() -> Self {
        Self { states: Vec::new() }
    }

    fn push(&mut self, state: State) -> Result<usize, ()> {
        if self.states.len() >= MAX_NFA_STATES {
            return Err(());
        }
        let idx = self.states.len();
        self.states.push(state);
        Ok(idx)
    }

    fn patch_end(&mut self, end_idx: usize, target: usize) {
        self.states[end_idx] = State::Jump(target);
    }

    fn compile(&mut self, ast: &Ast) -> Result<Fragment, ()> {
        match ast {
            Ast::Empty => {
                let s = self.push(State::Jump(UNSET))?;
                Ok(Fragment { start: s, end: s })
            }
            Ast::Matcher(matcher) => {
                let end = self.push(State::Jump(UNSET))?;
                let start = self.push(State::Step(matcher.clone(), end))?;
                Ok(Fragment { start, end })
            }
            Ast::Assert(kind) => {
                let end = self.push(State::Jump(UNSET))?;
                let start = self.push(State::Assert(*kind, end))?;
                Ok(Fragment { start, end })
            }
            Ast::Concat(items) => {
                if items.is_empty() {
                    return self.compile(&Ast::Empty);
                }
                let mut cur = self.compile(&items[0])?;
                for item in &items[1..] {
                    let next = self.compile(item)?;
                    self.patch_end(cur.end, next.start);
                    cur.end = next.end;
                }
                Ok(cur)
            }
            Ast::Alt(branches) => {
                if branches.is_empty() {
                    return self.compile(&Ast::Empty);
                }
                let mut compiled = Vec::with_capacity(branches.len());
                for b in branches {
                    compiled.push(self.compile(b)?);
                }
                let end = self.push(State::Jump(UNSET))?;
                for b in &compiled {
                    self.patch_end(b.end, end);
                }
                let mut start = compiled.pop().ok_or(())?.start;
                while let Some(prev) = compiled.pop() {
                    start = self.push(State::Split(prev.start, start))?;
                }
                Ok(Fragment { start, end })
            }
            Ast::Repeat { inner, min, max } => self.compile_repeat(inner, *min, *max),
        }
    }

    fn compile_repeat(
        &mut self,
        inner: &Ast,
        min: usize,
        max: Option<usize>,
    ) -> Result<Fragment, ()> {
        match max {
            None => {
                if min == 0 {
                    let sub = self.compile(inner)?;
                    let end = self.push(State::Jump(UNSET))?;
                    let split = self.push(State::Split(sub.start, end))?;
                    self.patch_end(sub.end, split);
                    Ok(Fragment { start: split, end })
                } else {
                    let mut parts = Vec::with_capacity(min);
                    for _ in 0..(min - 1) {
                        parts.push(self.compile(inner)?);
                    }
                    let tail = self.compile(inner)?;
                    let end = self.push(State::Jump(UNSET))?;
                    let split = self.push(State::Split(tail.start, end))?;
                    self.patch_end(tail.end, split);
                    let tail_frag = Fragment {
                        start: tail.start,
                        end,
                    };
                    if parts.is_empty() {
                        return Ok(tail_frag);
                    }
                    let mut cur = parts.remove(0);
                    for p in parts {
                        self.patch_end(cur.end, p.start);
                        cur.end = p.end;
                    }
                    self.patch_end(cur.end, tail_frag.start);
                    Ok(Fragment {
                        start: cur.start,
                        end: tail_frag.end,
                    })
                }
            }
            Some(max_cnt) => {
                if max_cnt == 0 {
                    return self.compile(&Ast::Empty);
                }
                let mut cur: Option<Fragment> = None;
                for _ in 0..min {
                    let frag = self.compile(inner)?;
                    cur = Some(match cur {
                        None => frag,
                        Some(mut prev) => {
                            self.patch_end(prev.end, frag.start);
                            prev.end = frag.end;
                            prev
                        }
                    });
                }
                for _ in min..max_cnt {
                    let sub = self.compile(inner)?;
                    let opt_end = self.push(State::Jump(UNSET))?;
                    let split = self.push(State::Split(sub.start, opt_end))?;
                    self.patch_end(sub.end, opt_end);
                    let frag = Fragment {
                        start: split,
                        end: opt_end,
                    };
                    cur = Some(match cur {
                        None => frag,
                        Some(mut prev) => {
                            self.patch_end(prev.end, frag.start);
                            prev.end = frag.end;
                            prev
                        }
                    });
                }
                cur.ok_or(())
            }
        }
    }
}

fn check_assert(kind: AssertKind, pos: usize, text_chars: &[char]) -> bool {
    match kind {
        AssertKind::Start => pos == 0,
        AssertKind::End => pos == text_chars.len(),
        AssertKind::WordBoundary | AssertKind::NotWordBoundary => {
            let left_word = pos > 0 && is_word_char(text_chars[pos - 1]);
            let right_word = pos < text_chars.len() && is_word_char(text_chars[pos]);
            let is_boundary = left_word != right_word;
            if kind == AssertKind::WordBoundary {
                is_boundary
            } else {
                !is_boundary
            }
        }
    }
}

fn expand_epsilon(
    states: &[State],
    seed_states: &[usize],
    pos: usize,
    text_chars: &[char],
    visited: &mut [bool],
    stack: &mut Vec<usize>,
    active_steps: &mut Vec<usize>,
) -> bool {
    visited.fill(false);
    stack.clear();
    active_steps.clear();

    for &s in seed_states {
        if s < states.len() && !visited[s] {
            visited[s] = true;
            stack.push(s);
        }
    }

    while let Some(idx) = stack.pop() {
        match &states[idx] {
            State::Match => return true,
            State::Jump(next) => {
                if *next != UNSET && *next < states.len() && !visited[*next] {
                    visited[*next] = true;
                    stack.push(*next);
                }
            }
            State::Split(a, b) => {
                if *b != UNSET && *b < states.len() && !visited[*b] {
                    visited[*b] = true;
                    stack.push(*b);
                }
                if *a != UNSET && *a < states.len() && !visited[*a] {
                    visited[*a] = true;
                    stack.push(*a);
                }
            }
            State::Assert(kind, next) => {
                if check_assert(*kind, pos, text_chars)
                    && *next != UNSET
                    && *next < states.len()
                    && !visited[*next]
                {
                    visited[*next] = true;
                    stack.push(*next);
                }
            }
            State::Step(_, _) => {
                active_steps.push(idx);
            }
        }
    }
    false
}

fn strip_js_regex_wrapper(pat: &str) -> (&str, Option<bool>) {
    if !pat.starts_with('/') || pat.len() < 2 {
        return (pat, None);
    }
    let Some(rel_last) = pat[1..].rfind('/') else {
        return (pat, None);
    };
    let last_slash = 1 + rel_last;
    if last_slash <= 1 {
        return (pat, None);
    }
    let backslashes_before = pat[..last_slash]
        .chars()
        .rev()
        .take_while(|&c| c == '\\')
        .count();
    if backslashes_before % 2 == 1 {
        return (pat, None);
    }
    let flags = &pat[last_slash + 1..];
    if !flags
        .chars()
        .all(|c| matches!(c, 'i' | 'm' | 's' | 'u' | 'g' | 'y' | 'd'))
    {
        return (pat, None);
    }
    let body = &pat[1..last_slash];
    let flag_override = flags.contains('i').then_some(true);
    (body, flag_override)
}

fn parse_pattern_and_flags(raw: &str) -> Option<(&str, bool)> {
    if raw.is_empty() {
        return None;
    }
    let (mut pat, wrapper_ci) = strip_js_regex_wrapper(raw);
    let mut case_insensitive = wrapper_ci.unwrap_or(true);

    loop {
        if let Some(rest) = pat.strip_prefix("(?-i)") {
            case_insensitive = false;
            pat = rest;
        } else if let Some(rest) = pat.strip_prefix("(?i)") {
            case_insensitive = true;
            pat = rest;
        } else {
            break;
        }
    }

    if pat.is_empty() {
        return None;
    }
    Some((pat, case_insensitive))
}

/// Returns `true` if `pattern` matches anywhere in `text`.
///
/// Defaults to case-insensitive matching; `(?-i)` disables it and `/pat/i` wrappers
/// are unwrapped automatically. Malformed or overly complex patterns return `false`.
pub fn regex_is_match(pattern: &str, text: &str) -> bool {
    CompiledRegex::new(pattern).is_some_and(|regex| regex.is_match(text))
}

pub(crate) struct CompiledRegex {
    states: Vec<State>,
    start: usize,
    case_insensitive: bool,
}

impl CompiledRegex {
    pub(crate) fn new(pattern: &str) -> Option<Self> {
        let (pat, case_insensitive) = parse_pattern_and_flags(pattern)?;

        let pat_chars: Vec<char> = pat.chars().collect();
        let mut parser = Parser {
            chars: &pat_chars,
            pos: 0,
        };
        let Ok(ast) = parser.parse_alt(0) else {
            return None;
        };
        if parser.pos != pat_chars.len() {
            return None;
        }

        let mut builder = NfaBuilder::new();
        let Ok(frag) = builder.compile(&ast) else {
            return None;
        };
        let Ok(match_state) = builder.push(State::Match) else {
            return None;
        };
        builder.patch_end(frag.end, match_state);

        Some(Self {
            states: builder.states,
            start: frag.start,
            case_insensitive,
        })
    }

    pub(crate) fn is_match(&self, text: &str) -> bool {
        let states = &self.states;
        let text_chars: Vec<char> = text.chars().collect();

        let mut current = Vec::with_capacity(16);
        let mut active_steps = Vec::with_capacity(16);
        let mut next_states = Vec::with_capacity(16);
        let mut stack = Vec::with_capacity(states.len());
        let mut visited = vec![false; states.len()];

        for pos in 0..=text_chars.len() {
            if !current.contains(&self.start) {
                current.push(self.start);
            }
            if expand_epsilon(
                states,
                &current,
                pos,
                &text_chars,
                &mut visited,
                &mut stack,
                &mut active_steps,
            ) {
                return true;
            }
            if pos == text_chars.len() {
                break;
            }

            let ch = text_chars[pos];
            next_states.clear();
            for &step_idx in &active_steps {
                if let State::Step(matcher, out) = &states[step_idx]
                    && matcher.matches(ch, self.case_insensitive)
                    && *out != UNSET
                    && !next_states.contains(out)
                {
                    next_states.push(*out);
                }
            }
            std::mem::swap(&mut current, &mut next_states);
        }

        false
    }
}

#[cfg(test)]
mod tests {
    use super::regex_is_match;

    #[test]
    fn test_basic_literals_alternation_and_unicode() {
        assert!(regex_is_match(
            "LTE",
            "🇫🇮 🎮 ⭐ 0.1X - LTE №134 - Hysteria2"
        ));
        assert!(regex_is_match(
            "lte",
            "🇨🇭 ⚡ ⭐ 0.1X - LTE №136 - Швейцария"
        ));
        assert!(!regex_is_match("LTE", "🇩🇪 Германия #2"));

        assert!(regex_is_match("LTE|3G", "Node 3G #4"));
        assert!(regex_is_match("LTE|3G", "Node LTE #1"));
        assert!(!regex_is_match("LTE|3G", "Node 5G #1"));

        assert!(regex_is_match(r"0\.1X.*LTE", "0.1X - LTE №59"));
        assert!(!regex_is_match(r"0\.1X.*LTE", "051X - LTE №59"));

        assert!(regex_is_match("^🇫🇮", "🇫🇮 Финляндия"));
        assert!(!regex_is_match("^🇫🇮", "🇩🇪 🇫🇮 Германия"));

        assert!(regex_is_match(r"№\d+", "0.1X - LTE №134 - Hysteria2"));
        assert!(!regex_is_match(r"№\d+", "0.1X - LTE № - Hysteria2"));

        assert!(regex_is_match(r"\[WL\]", "Main [WL] Node"));
        assert!(!regex_is_match(r"\[WL\]", "Main WL Node"));

        assert!(regex_is_match("Обход", "Сервер Обход #1"));
        assert!(regex_is_match("обход", "Сервер Обход #1"));
    }

    #[test]
    fn test_flags_groups_classes_and_boundaries() {
        assert!(!regex_is_match("(?-i)lte", "0.1X - LTE №59"));
        assert!(regex_is_match("(?-i)LTE", "0.1X - LTE №59"));
        assert!(regex_is_match("/lte/i", "0.1X - LTE №59"));
        assert!(regex_is_match("/^LTE/", "lte node"));

        assert!(regex_is_match(
            "(?:Hysteria2|VLESS)$",
            "🇪🇪 ⚡ LTE №98 - Hysteria2"
        ));
        assert!(regex_is_match("(?:Hysteria2|VLESS)$", "🇩🇪 Node VLESS"));
        assert!(!regex_is_match(
            "(?:Hysteria2|VLESS)$",
            "🇨🇭 LTE №136 - Швейцария"
        ));

        assert!(regex_is_match(r"\bLTE\b", "0.1X - LTE №59"));
        assert!(!regex_is_match(r"\bLTE\b", "XLTE2"));

        assert!(regex_is_match("№[0-9]{2,3}", "LTE №98"));
        assert!(!regex_is_match(r"№[0-9]{3}\b", "LTE №98"));
        assert!(regex_is_match(r"[^0-9]LTE", " LTE"));
        assert!(!regex_is_match(r"^[^a-z]+$", "abc"));
        assert!(regex_is_match("a+?b", "aaab"));
    }

    #[test]
    fn test_redos_safety_and_invalid_patterns() {
        let long_a = "a".repeat(250);
        assert!(!regex_is_match("(a+)+b", &long_a));
        assert!(!regex_is_match("[unclosed", "anything"));
        assert!(!regex_is_match("(unclosed", "anything"));
        assert!(!regex_is_match("*leading", "anything"));
        assert!(!regex_is_match("", "anything"));
        assert!(!regex_is_match("a{999}", "aaa"));
    }
}
