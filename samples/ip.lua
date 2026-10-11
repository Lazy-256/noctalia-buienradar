-- Shapes of https://ipwho.is/ answers, used only by test/run.lua. The values are made up (Amsterdam city
-- centre); the real answer also carries the IP address, provider and more, which are deliberately left out.
return {
  amsterdam = { success = true, city = "Amsterdam", region = "Noord-Holland", country_code = "NL", latitude = 52.374, longitude = 4.8897 },
  coordinates_only = { success = true, country_code = "NL", latitude = 52.3824, longitude = 4.8995 },
  failed = { success = false, message = "rate limited" },
}
