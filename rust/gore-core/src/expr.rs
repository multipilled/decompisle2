//! Tiny evaluator for DI2-style knowledge-base expressions, e.g.
//! `floatbranch(!#HasBothLegs, #HasBothArms, true)` or `#HasAnArm || !IsPutrefied`.
//!
//! Grammar:
//!   expr    := or
//!   or      := and ("||" and)*
//!   and     := cmp ("&&" cmp)*
//!   cmp     := unary (("=="|"!="|"<"|"<="|">"|">=") unary)?
//!   unary   := "!" unary | "-" unary | primary
//!   primary := number | "true" | "false" | "#"? ident | ident "(" args ")" | "{" ident "}" "." ident | "(" expr ")"
//!
//! Facts are looked up by name (without `#`); unknown facts are 0/false. `{hit}.X` reads fact `hit.X`.

use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Num(f64),
    Fact(String),
    Not(Box<Expr>),
    Neg(Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Cmp(Box<Expr>, CmpOp, Box<Expr>),
    Call(String, Vec<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParseError {
    pub pos: usize,
    pub msg: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "expression error at {}: {}", self.pos, self.msg)
    }
}

impl std::error::Error for ParseError {}

/// Source of fact values for evaluation.
pub trait Facts {
    fn get(&self, name: &str) -> f64;
}

impl Facts for HashMap<String, f64> {
    fn get(&self, name: &str) -> f64 {
        HashMap::get(self, name).copied().unwrap_or(0.0)
    }
}

impl<F: Fn(&str) -> f64> Facts for F {
    fn get(&self, name: &str) -> f64 {
        self(name)
    }
}

impl Expr {
    /// Parses an expression. An empty string parses to `true` (DI2 leaves unset rules blank).
    pub fn parse(src: &str) -> Result<Expr, ParseError> {
        let mut p = Parser { s: src.as_bytes(), i: 0 };
        p.ws();
        if p.i == p.s.len() {
            return Ok(Expr::Num(1.0));
        }
        let e = p.or()?;
        p.ws();
        if p.i != p.s.len() {
            return Err(p.err("trailing input"));
        }
        Ok(e)
    }

    pub fn eval(&self, facts: &dyn Facts) -> f64 {
        match self {
            Expr::Num(n) => *n,
            Expr::Fact(name) => facts.get(name),
            Expr::Not(e) => b(e.eval(facts) == 0.0),
            Expr::Neg(e) => -e.eval(facts),
            Expr::And(a, c) => b(a.eval(facts) != 0.0 && c.eval(facts) != 0.0),
            Expr::Or(a, c) => b(a.eval(facts) != 0.0 || c.eval(facts) != 0.0),
            Expr::Cmp(a, op, c) => {
                let (x, y) = (a.eval(facts), c.eval(facts));
                b(match op {
                    CmpOp::Eq => (x - y).abs() < 1e-9,
                    CmpOp::Ne => (x - y).abs() >= 1e-9,
                    CmpOp::Lt => x < y,
                    CmpOp::Le => x <= y,
                    CmpOp::Gt => x > y,
                    CmpOp::Ge => x >= y,
                })
            }
            Expr::Call(name, args) => call(name, args, facts),
        }
    }

    pub fn eval_bool(&self, facts: &dyn Facts) -> bool {
        self.eval(facts) != 0.0
    }
}

fn b(v: bool) -> f64 {
    if v {
        1.0
    } else {
        0.0
    }
}

fn call(name: &str, args: &[Expr], facts: &dyn Facts) -> f64 {
    let arg = |i: usize| args.get(i).map(|e| e.eval(facts)).unwrap_or(0.0);
    match name.to_ascii_lowercase().as_str() {
        "floatbranch" | "branch" | "if" => {
            if arg(0) != 0.0 {
                arg(1)
            } else {
                arg(2)
            }
        }
        "min" => arg(0).min(arg(1)),
        "max" => arg(0).max(arg(1)),
        "abs" => arg(0).abs(),
        "clamp" => arg(0).clamp(arg(1), arg(2)),
        _ => 0.0,
    }
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn err(&self, msg: &str) -> ParseError {
        ParseError { pos: self.i, msg: msg.to_string() }
    }

    fn ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }

    fn eat(&mut self, tok: &str) -> bool {
        self.ws();
        if self.s[self.i..].starts_with(tok.as_bytes()) {
            self.i += tok.len();
            true
        } else {
            false
        }
    }

    fn or(&mut self) -> Result<Expr, ParseError> {
        let mut e = self.and()?;
        while self.eat("||") {
            e = Expr::Or(Box::new(e), Box::new(self.and()?));
        }
        Ok(e)
    }

    fn and(&mut self) -> Result<Expr, ParseError> {
        let mut e = self.cmp()?;
        while self.eat("&&") {
            e = Expr::And(Box::new(e), Box::new(self.cmp()?));
        }
        Ok(e)
    }

    fn cmp(&mut self) -> Result<Expr, ParseError> {
        let e = self.unary()?;
        for (tok, op) in [
            ("==", CmpOp::Eq),
            ("!=", CmpOp::Ne),
            ("<=", CmpOp::Le),
            (">=", CmpOp::Ge),
            ("<", CmpOp::Lt),
            (">", CmpOp::Gt),
        ] {
            if self.eat(tok) {
                return Ok(Expr::Cmp(Box::new(e), op, Box::new(self.unary()?)));
            }
        }
        Ok(e)
    }

    fn unary(&mut self) -> Result<Expr, ParseError> {
        self.ws();
        if self.i < self.s.len() && self.s[self.i] == b'!' && self.s.get(self.i + 1) != Some(&b'=') {
            self.i += 1;
            return Ok(Expr::Not(Box::new(self.unary()?)));
        }
        if self.eat("-") {
            return Ok(Expr::Neg(Box::new(self.unary()?)));
        }
        self.primary()
    }

    fn ident(&mut self) -> Option<String> {
        self.ws();
        let start = self.i;
        while self.i < self.s.len() && (self.s[self.i].is_ascii_alphanumeric() || self.s[self.i] == b'_') {
            self.i += 1;
        }
        (self.i > start).then(|| String::from_utf8_lossy(&self.s[start..self.i]).into_owned())
    }

    fn primary(&mut self) -> Result<Expr, ParseError> {
        self.ws();
        if self.eat("(") {
            let e = self.or()?;
            if !self.eat(")") {
                return Err(self.err("expected ')'"));
            }
            return Ok(e);
        }
        if self.eat("{") {
            let scope = self.ident().ok_or_else(|| self.err("expected scope name"))?;
            if !self.eat("}") || !self.eat(".") {
                return Err(self.err("expected '}.'"));
            }
            let field = self.ident().ok_or_else(|| self.err("expected field name"))?;
            return Ok(Expr::Fact(format!("{scope}.{field}")));
        }
        let hash = self.eat("#");
        self.ws();
        if !hash && self.i < self.s.len() && (self.s[self.i].is_ascii_digit() || self.s[self.i] == b'.') {
            let start = self.i;
            while self.i < self.s.len() && (self.s[self.i].is_ascii_digit() || self.s[self.i] == b'.') {
                self.i += 1;
            }
            let txt = std::str::from_utf8(&self.s[start..self.i]).unwrap();
            return txt.parse().map(Expr::Num).map_err(|_| self.err("bad number"));
        }
        let name = self.ident().ok_or_else(|| self.err("expected identifier"))?;
        if !hash {
            match name.as_str() {
                "true" => return Ok(Expr::Num(1.0)),
                "false" => return Ok(Expr::Num(0.0)),
                _ => {}
            }
            if self.eat("(") {
                let mut args = Vec::new();
                if !self.eat(")") {
                    loop {
                        args.push(self.or()?);
                        if self.eat(")") {
                            break;
                        }
                        if !self.eat(",") {
                            return Err(self.err("expected ',' or ')'"));
                        }
                    }
                }
                return Ok(Expr::Call(name, args));
            }
        }
        Ok(Expr::Fact(name))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(pairs: &[(&str, f64)]) -> HashMap<String, f64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn walker_survival_rule() {
        let e = Expr::parse("floatbranch(!#HasBothLegs, #HasBothArms, true)").unwrap();
        assert!(e.eval_bool(&facts(&[("HasBothLegs", 1.0), ("HasBothArms", 0.0)])));
        assert!(e.eval_bool(&facts(&[("HasBothLegs", 0.0), ("HasBothArms", 1.0)])));
        assert!(!e.eval_bool(&facts(&[("HasBothLegs", 0.0), ("HasBothArms", 0.0)])));
    }

    #[test]
    fn slobber_rule_and_hit_scope() {
        let e = Expr::parse("#HasAnArm || !IsPutrefied").unwrap();
        assert!(!e.eval_bool(&facts(&[("HasAnArm", 0.0), ("IsPutrefied", 1.0)])));
        let h = Expr::parse("(#IsArmouredImpact || {hit}.ArmourPieceBroken)").unwrap();
        assert!(h.eval_bool(&facts(&[("hit.ArmourPieceBroken", 1.0)])));
    }

    #[test]
    fn empty_is_true_and_errors_report() {
        assert!(Expr::parse("").unwrap().eval_bool(&HashMap::new()));
        assert!(Expr::parse("floatbranch(1, 2").is_err());
        assert_eq!(Expr::parse("2 >= 1 && !0").unwrap().eval(&HashMap::new()), 1.0);
    }
}
