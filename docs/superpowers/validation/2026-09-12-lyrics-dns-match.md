# Restored lyrics connectivity and soundtrack-title matching

Network root cause: live mihomo DNS query returned 127.0.0.1 for lrclib.net; live logs confirmed IPCIDR/127.0.0.0/8 → DIRECT → local port443 connection refused. A Google DNS-over-HTTPS query returned public Cloudflare addresses, and a certificate-verified one-request connection override returned the expected lyric payload. No TLS verification was disabled.

Applied a domain-specific nameserver-policy for lrclib.net → https://dns.google/dns-query in Clash Verge global profiles/Merge.yaml and current generated config. Backups are in /tmp/interesting-notch-dns-backup with restricted permissions. Validated config using verge-mihomo -t, hot-reloaded and flushed its DNS cache. Fresh DNS returned public addresses; normal URLSession returned HTTP200. Live successful connection matched the existing Match rule and its existing proxy selector. No global node selection or mode was changed.

Application fix: strict title matching rejected a record titled 偏爱-《仙剑奇侠传3》电视剧插曲. Added conservative normalization for explicit 《work》 soundtrack-use suffixes only. Artist, duration tolerance and duplicate-version checks remain; Live/Remix are preserved. Real API check matched 57 timed lines for this track.

Verification: current playback changed to 苏州河; production fetch code matched 34 lines and 33 segments. After signed installation and restart, actual app stderr recorded Lyrics loaded: 34 lines. Thus live fetching, not only a test HTTP request, recovered. CompactLyricsChecks and full Debug xcodebuild passed; git diff --check and codesign verification passed. Installed stable path unchanged. The screen was not captured as visual lyric evidence.
