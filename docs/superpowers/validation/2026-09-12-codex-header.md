# Existing top toolbar Codex information

Uses only the existing header row: allowance follows Home/Shelf on the left; selected task model/effort precedes Settings/Battery on the right. The physical notch spacer and expanded height/width are unchanged. Header halves have equal measured widths to keep content outside the camera region. Battery intrinsic width is preserved; model text truncates in the middle with complete provider/model/effort in help and accessibility.

Bridge exposes both 300-minute and weekly allowances for Plus, weekly only for supported Pro/organization plans. Existing closed fuel selection is unchanged. Model and provider are projected from task settings snapshots and patches, with bounded sanitized strings; no transcript fields exported. Waiting tasks sort first, otherwise highest known effort; identity breaks ties deterministically and multiple-task count is visible. Idle/unknown states are explicit.

Python quota/model/IPC regression checks, Swift selection/freshness/geometry checks and full Debug build passed. Native expanded UI confirmed existing Home/Shelf, Settings, single-line 95% battery, weekly 11% allowance and abbreviated model plus medium effort in the same top row. Accessibility confirmed actual gpt-6-astra, openai, medium. Installed signed build, restarted, and verified loaded dylib plus build UUID. Plus layout data selection is covered by tests, not a live Plus account.

## Left-only labels

Allowance and model now share the left side of the existing toolbar, in that order. Header tabs use 7pt horizontal padding to free space, with original padding elsewhere. Right-hand model text removed. Explicit labels: 5.6/luna -> 露娜 plus effort, terra/tara -> Tara plus effort, sol/so -> so 思考强度 plus effort, GPT-6 -> Astra, GPT-5.5 -> 5.5; medium is mid. Full raw model and effort remain in help. Swift mapping checks and full Debug build passed; signed app installed/restarted. Native expanded screenshot confirmed 周 11% · Astra on the left, original settings and single-line battery on the right.

## Native model names and single allowance

Verified local app-server model/list displayName values (GPT-6-Astra, GPT-5.6-Luna/Terra/Sol, GPT-5.5, GPT-5.3-Codex-Spark). Header preserves these names minus the previously requested GPT prefix and always appends effort (medium -> mid). Removed custom Chinese and misspelled aliases. Header uses the same selected fuel as the closed gauge: Plus 300 minutes, supported Pro tiers weekly; only percent is shown. Native screenshot confirms 10% · 6-Astra mid in the existing left header. Mapping checks, Debug build and whitespace checks passed; signed updated app restarted.
