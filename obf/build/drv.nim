import std/syncio
import validator
proc t(p, v: string) = echo p, ": ", v, "  ->  ", valueMatches(p, v)
when isMainModule:
  t("color", "red"); t("color", "10px"); t("display", "flex")
  t("margin", "10px 20px"); t("border", "1px solid black")
