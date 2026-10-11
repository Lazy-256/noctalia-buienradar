-- Trimmed responses of https://geocoding-api.open-meteo.com/v1/search?count=1&language=nl (taken 2026-10-11),
-- used only by test/run.lua. Keys are "<name lower case>|<COUNTRY CODE>" of the request; "emmmen|NL" is the
-- shape of an answer without a match (no `results`).
-- Source: Open-Meteo geocoding (https://open-meteo.com/en/docs/geocoding-api), data from GeoNames (CC BY 4.0).
return {
  ["emmen|NL"] = {["generationtime_ms"]=0.268, ["results"]={{["id"]=2756136, ["name"]="Emmen", ["latitude"]=52.77917, ["longitude"]=6.90694, ["country_code"]="NL", ["admin1"]="Drenthe"}}},
  ["the hague|NL"] = {["generationtime_ms"]=0.529, ["results"]={{["id"]=2747373, ["name"]="Den Haag", ["latitude"]=52.07667, ["longitude"]=4.29861, ["country_code"]="NL", ["admin1"]="Zuid-Holland"}}},
  ["den haag|NL"] = {["generationtime_ms"]=0.564, ["results"]={{["id"]=2747373, ["name"]="Den Haag", ["latitude"]=52.07667, ["longitude"]=4.29861, ["country_code"]="NL", ["admin1"]="Zuid-Holland"}}},
  ["groningen|"] = {["generationtime_ms"]=0.441, ["results"]={{["id"]=2755251, ["name"]="Groningen", ["latitude"]=53.21917, ["longitude"]=6.56667, ["country_code"]="NL", ["admin1"]="Groningen"}}},
  ["groningen|NL"] = {["generationtime_ms"]=0.72, ["results"]={{["id"]=2755251, ["name"]="Groningen", ["latitude"]=53.21917, ["longitude"]=6.56667, ["country_code"]="NL", ["admin1"]="Groningen"}}},
  ["'s-hertogenbosch|NL"] = {["generationtime_ms"]=0.153, ["results"]={{["id"]=2747351, ["name"]="'s-Hertogenbosch", ["latitude"]=51.69917, ["longitude"]=5.30417, ["country_code"]="NL", ["admin1"]="Noord-Brabant"}}},
  ["amsterdam|NL"] = {["generationtime_ms"]=0.613, ["results"]={{["id"]=2759794, ["name"]="Amsterdam", ["latitude"]=52.37403, ["longitude"]=4.88969, ["country_code"]="NL", ["admin1"]="Noord-Holland"}}},
  ["emmmen|NL"] = {["generationtime_ms"]=0.246},
  ["berlin|DE"] = {["generationtime_ms"]=0.643, ["results"]={{["id"]=2950159, ["name"]="Berlijn", ["latitude"]=52.52437, ["longitude"]=13.41053, ["country_code"]="DE", ["admin1"]="Deelstaat Berlijn"}}},
}
