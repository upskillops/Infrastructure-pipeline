#!/usr/bin/env python3
"""Generate gitlab-aws-cost-analysis.html from the model.

Everything visible in the output is computed from model.py, so the diagram,
the chart and the table cannot drift from each other or from the rates.
"""
import html, pathlib
from model import ITEMS, GROUPS, SAVINGS, subtotal, total
from rates import RATES, HOURS

OUT = pathlib.Path(__file__).resolve().parent.parent / "gitlab-aws-cost-analysis.html"
e = lambda s: html.escape(str(s))
money = lambda v: f"${v:,.2f}"

# Validated categorical slots 1-3 (see references/palette.md); all-pairs clean
# in both modes. Light-mode aqua is below 3:1 on the surface, so the relief
# rule applies -- hence direct labels on every bar AND the full table below.
CLR = {"gitlab": "var(--series-1)", "shared": "var(--series-2)", "other": "var(--series-3)"}

# ---------------------------------------------------------------- diagram
def diagram():
    W = 1080
    p = []
    def boxh(nlines):
        """Height that actually fits a title plus n sub-lines, with padding."""
        return 40 + max(0, nlines - 1) * 15 + (14 if nlines else 0)
    def box(x, y, w, h, title, lines, fill="var(--card)", stroke="var(--rule)", accent=None, cost=None):
        p.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        if accent:
            p.append(f'<rect x="{x}" y="{y}" width="4" height="{h}" rx="2" fill="{accent}"/>')
        p.append(f'<text x="{x+14}" y="{y+22}" class="bx-t">{e(title)}</text>')
        for i, ln in enumerate(lines):
            p.append(f'<text x="{x+14}" y="{y+40+i*15}" class="bx-s">{e(ln)}</text>')
        if cost:
            p.append(f'<text x="{x+w-12}" y="{y+22}" class="bx-c" text-anchor="end">{e(cost)}</text>')
    def arrow(x, y1, y2, label=None):
        p.append(f'<line x1="{x}" y1="{y1}" x2="{x}" y2="{y2-7}" stroke="var(--rule-strong)" stroke-width="2" marker-end="url(#ar)"/>')
        if label:
            p.append(f'<text x="{x+10}" y="{(y1+y2)/2+4}" class="bx-e">{e(label)}</text>')

    CX = W/2
    p.append(f'<rect x="{CX-190}" y="16" width="380" height="40" rx="8" fill="var(--surface-2)" stroke="var(--rule)" stroke-width="1.5"/>')
    p.append(f'<text x="{CX}" y="41" class="bx-t" text-anchor="middle">Internet — browsers, git clients, CI runners</text>')

    h2 = boxh(2)
    y = 56; arrow(CX, y, y+28); y += 28
    box(CX-190, y, 380, h2, "Route 53",
        ["public hosted zone · gitlab.<domain>", "records written by external-dns"],
        cost=money(RATES["route53.zone"][0]))
    y += h2; arrow(CX, y, y+28); y += 28
    box(CX-190, y, 380, h2, "Network Load Balancer",
        ["internet-facing, ip targets", "created by AWS LBC from Envoy Gateway"],
        cost=money(HOURS*RATES["nlb.hour"][0] + 5*HOURS*RATES["nlb.lcu"][0]))
    y += h2; arrow(CX, y, y+30)

    # VPC. Drawn last (see below) so its height can follow its contents; the
    # rect is spliced in at this index once the inner blocks are laid out.
    VY = y + 30
    vpc_slot = len(p)
    p.append("")
    p.append(f'<text x="44" y="{VY+26}" class="sec">VPC 10.0.0.0/16 · 3 availability zones</text>')

    # public subnets / NAT
    NY = VY + 40
    p.append(f'<rect x="48" y="{NY}" width="{W-96}" height="66" rx="8" fill="var(--card)" stroke="var(--rule)" stroke-width="1"/>')
    p.append(f'<text x="64" y="{NY+20}" class="bx-s">Public subnets ×3</text>')
    natw = (W-96-32-2*14)/3
    for i in range(3):
        nx = 64 + i*(natw+14)
        p.append(f'<rect x="{nx}" y="{NY+28}" width="{natw}" height="28" rx="6" fill="var(--surface-2)" stroke="var(--rule)"/>')
        p.append(f'<text x="{nx+10}" y="{NY+47}" class="bx-s">NAT Gateway · AZ {chr(97+i)}</text>')
    p.append(f'<text x="{W-64}" y="{NY+20}" class="bx-c" text-anchor="end">{money(3*HOURS*RATES["nat.hour"][0] + 150*RATES["nat.gb"][0])}</text>')

    # EKS
    EY, EH = NY + 86, 214
    p.append(f'<rect x="48" y="{EY}" width="{W-96}" height="{EH}" rx="10" fill="var(--card)" stroke="var(--rule-strong)" stroke-width="1.5"/>')
    p.append(f'<text x="64" y="{EY+24}" class="sec">EKS cluster · private subnets ×3 · Cilium CNI (no VPC CNI, no kube-proxy)</text>')
    p.append(f'<text x="{W-64}" y="{EY+24}" class="bx-c" text-anchor="end">control plane {money(HOURS*RATES["eks.cluster"][0])}</text>')
    cards = [
        ("core · 2 × m7g.large", ["Cilium operator, CoreDNS", "Karpenter, AWS LBC, external-dns"], "shared", 2*HOURS*RATES["m7g.large"][0] + 8.00),
        ("infra · 3 × m7g.xlarge", ["webservice, sidekiq, gitaly", "registry, kas, runner manager", "cert-manager, Envoy Gateway"], "gitlab", 3*HOURS*RATES["m7g.xlarge"][0] + 19.20),
        ("app · 3 × m7g.xlarge", ["application workloads", "taint workload=app"], "other", 3*HOURS*RATES["m7g.xlarge"][0] + 19.20),
        ("monitoring · 2 × r7g.xlarge", ["Prometheus, Loki", "taint workload=monitoring"], "other", 2*HOURS*RATES["r7g.xlarge"][0] + 24.00),
    ]
    cw = (W-96-32-3*14)/4
    for i,(t,ls,g,c) in enumerate(cards):
        cx = 64 + i*(cw+14)
        box(cx, EY+36, cw, 158, "", [], fill="var(--surface-2)", accent=CLR[g])
        p.append(f'<text x="{cx+16}" y="{EY+58}" class="bx-t">{e(t)}</text>')
        for j,l in enumerate(ls):
            p.append(f'<text x="{cx+16}" y="{EY+78+j*15}" class="bx-s">{e(l)}</text>')
        p.append(f'<text x="{cx+16}" y="{EY+182}" class="bx-c">{money(c)}/mo</text>')
    p.append(f'<text x="{64+cw+14+16}" y="{EY+150}" class="bx-e">◄ GitLab pinned here</text>')

    # data layer
    DY = EY + EH + 20
    p.append(f'<text x="64" y="{DY+14}" class="sec">Managed data services · private subnets</text>')
    dcards = [
        ("RDS PostgreSQL 17", ["db.m7g.large · Single-AZ", "100 GiB gp3 · 7-day backups"], HOURS*RATES["rds.m7g.large"][0] + 100*RATES["rds.gp3"][0]),
        ("ElastiCache Redis 7.1", ["cache.m7g.large · 1 node", "TLS + AUTH, no failover"], HOURS*RATES["cache.m7g.large"][0]),
        ("EBS · Gitaly volume", ["100 GiB gp3-infra", "4000 IOPS · 250 MB/s · Retain"], 18.00),
    ]
    dw = (W-96-32-2*14)/3
    for i,(t,ls,c) in enumerate(dcards):
        dx = 64 + i*(dw+14)
        box(dx, DY+26, dw, 76, "", [], accent=CLR["gitlab"])
        p.append(f'<text x="{dx+16}" y="{DY+48}" class="bx-t">{e(t)}</text>')
        for j,l in enumerate(ls):
            p.append(f'<text x="{dx+16}" y="{DY+68+j*15}" class="bx-s">{e(l)}</text>')
        p.append(f'<text x="{dx+dw-12}" y="{DY+48}" class="bx-c" text-anchor="end">{money(c)}</text>')

    # Now that the data cards are placed, the VPC box can be sized to them.
    VH = (DY + 26 + 76) + 20 - VY
    p[vpc_slot] = (f'<rect x="24" y="{VY}" width="{W-48}" height="{VH}" rx="12" '
                   f'fill="var(--surface-2)" stroke="var(--rule)" stroke-width="1.5" stroke-dasharray="6 4"/>')

    # regional services outside the VPC
    RY = VY + VH + 22
    p.append(f'<rect x="24" y="{RY}" width="{W-48}" height="62" rx="10" fill="var(--card)" stroke="var(--rule)" stroke-width="1.5"/>')
    p.append(f'<text x="44" y="{RY+24}" class="sec">Regional services — outside the VPC, reached via NAT</text>')
    p.append(f'<text x="44" y="{RY+46}" class="bx-s">S3 ×12 buckets — artifacts · LFS · uploads · packages · registry · backups · CI secure files · MR diffs · TF state · pages · tmp · dependency proxy</text>')
    p.append(f'<text x="{W-44}" y="{RY+24}" class="bx-c" text-anchor="end">{money(200*RATES["s3.standard"][0])}</text>')

    H = RY + 62 + 16
    return f'<svg viewBox="0 0 {W} {H}" width="100%" role="img" aria-label="AWS resources used by GitLab on EKS, with monthly cost per resource">' \
           f'<defs><marker id="ar" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">' \
           f'<path d="M 0 0 L 10 5 L 0 10 z" fill="var(--rule-strong)"/></marker></defs>' + "".join(p) + "</svg>"

# ---------------------------------------------------------------- bar chart
def chart():
    items = sorted(ITEMS, key=lambda i: -i.monthly)
    BH, GAP, X0, BW = 22, 9, 300, 600
    mx = max(i.monthly for i in items)
    H = len(items)*(BH+GAP) + 46
    p = [f'<text x="0" y="14" class="ax">monthly cost, USD</text>']
    for t in range(0, 401, 100):  # recessive gridlines
        gx = X0 + t/mx*BW
        p.append(f'<line x1="{gx:.1f}" y1="24" x2="{gx:.1f}" y2="{H-22}" stroke="var(--grid)" stroke-width="1"/>')
        p.append(f'<text x="{gx:.1f}" y="{H-8}" class="ax" text-anchor="middle">${t}</text>')
    for n,i in enumerate(items):
        y = 30 + n*(BH+GAP)
        w = max(3, i.monthly/mx*BW)
        tip = e(f"{i.name} — {i.detail} — {money(i.monthly)}/mo" + (f" · {i.note}" if i.note else ""))
        p.append(f'<g class="bar" tabindex="0" data-tip="{tip}">')
        p.append(f'<rect x="0" y="{y-4}" width="{X0+BW+90}" height="{BH+8}" fill="transparent"/>')
        p.append(f'<text x="{X0-12}" y="{y+15}" class="lbl" text-anchor="end">{e(i.name)}</text>')
        p.append(f'<rect x="{X0}" y="{y}" width="{w:.1f}" height="{BH}" rx="4" fill="{CLR[i.group]}"/>')
        p.append(f'<text x="{X0+w+9:.1f}" y="{y+15}" class="val">{money(i.monthly)}</text>')
        p.append('</g>')
    return f'<svg viewBox="0 0 1000 {H}" width="100%" role="img" aria-label="Monthly cost by resource, ranked">' + "".join(p) + "</svg>"

# ---------------------------------------------------------------- page
def table():
    rows = []
    for g,(label,sub) in GROUPS.items():
        rows.append(f'<tr class="gh"><th colspan="3"><span class="sw" style="background:{CLR[g]}"></span>{e(label)}'
                    f'<span class="gs">{e(sub)}</span></th><td class="num">{money(subtotal(g))}</td></tr>')
        for i in [x for x in ITEMS if x.group==g]:
            rows.append(f'<tr><td>{e(i.name)}</td><td class="dim">{e(i.detail)}</td>'
                        f'<td class="dim note">{e(i.note)}</td><td class="num">{money(i.monthly)}</td></tr>')
    return "".join(rows)

def savings():
    return "".join(
        f'<tr><td>{e(n)}</td><td class="dim note">{e(note)}</td><td class="num neg">−{money(v)}</td></tr>'
        for n,v,note in SAVINGS)

t, gl, sh = total(), subtotal("gitlab"), subtotal("shared")
saved = sum(v for _,v,_ in SAVINGS)

OUT.write_text(f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GitLab on EKS — AWS resource &amp; cost analysis</title>
<style>
  .viz-root {{
    color-scheme: light;
    --surface-1:#fcfcfb; --surface-2:#f2f2ef; --card:#ffffff;
    --text-primary:#0b0b0b; --text-secondary:#52514e; --text-muted:#78766f;
    --rule:#dedcd5; --rule-strong:#b4b1a8; --grid:#e8e6df;
    --series-1:#2a78d6; --series-2:#eb6834; --series-3:#1baf7a;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) .viz-root {{
      color-scheme: dark;
      --surface-1:#1a1a19; --surface-2:#232320; --card:#2a2a27;
      --text-primary:#ffffff; --text-secondary:#c3c2b7; --text-muted:#9b998f;
      --rule:#3d3c37; --rule-strong:#5f5d55; --grid:#333330;
      --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70;
    }}
  }}
  :root[data-theme="dark"] .viz-root {{
    color-scheme: dark;
    --surface-1:#1a1a19; --surface-2:#232320; --card:#2a2a27;
    --text-primary:#ffffff; --text-secondary:#c3c2b7; --text-muted:#9b998f;
    --rule:#3d3c37; --rule-strong:#5f5d55; --grid:#333330;
    --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70;
  }}
  * {{ box-sizing:border-box; }}
  /* --surface-1 is scoped to .viz-root, so body cannot read it -- let the
     root element fill the viewport instead of colouring body. */
  body {{ margin:0; }}
  .viz-root {{ min-height:100vh; background:var(--surface-1); color:var(--text-primary);
    font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif;
    padding:40px 28px 72px; }}
  .wrap {{ max-width:1140px; margin:0 auto; }}
  h1 {{ font-size:27px; margin:0 0 6px; letter-spacing:-.02em; }}
  h2 {{ font-size:18px; margin:44px 0 6px; letter-spacing:-.01em; }}
  .sub {{ color:var(--text-secondary); margin:0 0 6px; }}
  .cap {{ color:var(--text-muted); font-size:13px; margin:0 0 18px; }}
  .tiles {{ display:flex; gap:14px; flex-wrap:wrap; margin:26px 0 8px; }}
  .tile {{ flex:1 1 210px; background:var(--card); border:1px solid var(--rule);
    border-radius:10px; padding:16px 18px; }}
  .tile .k {{ font-size:12.5px; color:var(--text-secondary); text-transform:uppercase;
    letter-spacing:.06em; margin-bottom:7px; }}
  .tile .v {{ font-size:29px; font-weight:640; letter-spacing:-.02em;
    font-variant-numeric:tabular-nums; }}
  .tile .n {{ font-size:12.5px; color:var(--text-muted); margin-top:5px; }}
  .panel {{ background:var(--card); border:1px solid var(--rule); border-radius:12px;
    padding:20px; margin-top:14px; }}
  .legend {{ display:flex; gap:20px; flex-wrap:wrap; margin:0 0 16px;
    font-size:13.5px; color:var(--text-secondary); }}
  .sw {{ width:11px; height:11px; border-radius:3px; display:inline-block;
    margin-right:7px; vertical-align:-1px; }}
  table {{ width:100%; border-collapse:collapse; font-size:14px; }}
  th,td {{ text-align:left; padding:8px 10px; border-bottom:1px solid var(--rule); vertical-align:top; }}
  th {{ font-size:12.5px; text-transform:uppercase; letter-spacing:.05em; color:var(--text-secondary); }}
  .gh th {{ background:var(--surface-2); font-size:14px; text-transform:none;
    letter-spacing:0; color:var(--text-primary); }}
  .gh .gs {{ font-weight:400; color:var(--text-muted); font-size:12.5px; margin-left:10px; }}
  .gh td {{ background:var(--surface-2); }}
  .num {{ text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }}
  .neg {{ color:var(--series-3); }}
  .dim {{ color:var(--text-secondary); }}
  .note {{ font-size:13px; color:var(--text-muted); }}
  tfoot td {{ font-weight:650; border-top:2px solid var(--rule-strong); border-bottom:none; }}
  text {{ font-family:ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif; }}
  .sec {{ font-size:13px; font-weight:620; fill:var(--text-primary); }}
  .bx-t {{ font-size:13px; font-weight:600; fill:var(--text-primary); }}
  .bx-s {{ font-size:11.5px; fill:var(--text-secondary); }}
  .bx-c {{ font-size:12px; font-weight:620; fill:var(--text-primary);
    font-variant-numeric:tabular-nums; }}
  .bx-e {{ font-size:11.5px; font-weight:600; fill:var(--series-1); }}
  .lbl {{ font-size:12.5px; fill:var(--text-secondary); }}
  .val {{ font-size:12.5px; font-weight:620; fill:var(--text-primary);
    font-variant-numeric:tabular-nums; }}
  .ax  {{ font-size:11.5px; fill:var(--text-muted); }}
  .bar {{ cursor:default; outline:none; }}
  .bar:hover rect:not([fill=transparent]), .bar:focus-visible rect:not([fill=transparent]) {{ opacity:.82; }}
  .bar:focus-visible .lbl, .bar:hover .lbl {{ fill:var(--text-primary); }}
  #tip {{ position:fixed; z-index:9; max-width:330px; background:var(--card);
    color:var(--text-primary); border:1px solid var(--rule-strong); border-radius:8px;
    padding:9px 11px; font-size:12.5px; line-height:1.45; pointer-events:none;
    opacity:0; transition:opacity .1s; box-shadow:0 4px 16px rgb(0 0 0 / .13); }}
  .warn {{ border-left:3px solid var(--series-2); padding-left:14px; margin:16px 0;
    color:var(--text-secondary); font-size:14px; }}
</style></head>
<body><div class="viz-root"><div class="wrap">

<h1>GitLab on EKS — AWS resources and cost</h1>
<p class="sub">Everything <code>terraform-karpenter-nodepools</code> provisions at its default variable values, priced at on-demand rates.</p>
<p class="cap">us-east-1 · {HOURS} hours/month · rates pulled from the AWS Pricing API on 2026-09-19 · generated by <code>cost/build.py</code></p>

<div class="tiles">
  <div class="tile"><div class="k">Total / month</div><div class="v">{money(t)}</div><div class="n">{money(t*12)} per year</div></div>
  <div class="tile"><div class="k">GitLab only</div><div class="v">{money(gl)}</div><div class="n">{gl/t*100:.0f}% of the bill · disappears if enable_gitlab = false</div></div>
  <div class="tile"><div class="k">GitLab + shared cluster</div><div class="v">{money(gl+sh)}</div><div class="n">what a GitLab-only cluster would cost</div></div>
  <div class="tile"><div class="k">After the savings levers</div><div class="v">{money(t-saved)}</div><div class="n">−{money(saved)}/mo · see below</div></div>
</div>

<h2>What gets created</h2>
<p class="cap">Blue = billed to GitLab · orange = shared cluster · green = other workload tiers. Costs shown are monthly.</p>
<div class="panel">{diagram()}</div>

<h2>Cost by resource</h2>
<div class="legend">
  <span><span class="sw" style="background:var(--series-1)"></span>GitLab</span>
  <span><span class="sw" style="background:var(--series-2)"></span>Shared cluster</span>
  <span><span class="sw" style="background:var(--series-3)"></span>app + monitoring tiers</span>
</div>
<div class="panel">{chart()}</div>

<div class="warn"><strong>Compute is {(sum(i.monthly for i in ITEMS if "node group" in i.name)/t*100):.0f}% of the bill.</strong>
Ten on-demand nodes cost {money(sum(i.monthly for i in ITEMS if "node group" in i.name))}/month. Every other line item put together is
{money(t - sum(i.monthly for i in ITEMS if "node group" in i.name))}. Optimise node count and commitment before anything else.</div>

<h2>Itemised</h2>
<table>
  <thead><tr><th>Resource</th><th>Quantity</th><th>Note</th><th class="num">$/month</th></tr></thead>
  <tbody>{table()}</tbody>
  <tfoot><tr><td colspan="3">Total</td><td class="num">{money(t)}</td></tr></tfoot>
</table>

<h2>Savings levers</h2>
<table>
  <thead><tr><th>Change</th><th>Trade-off</th><th class="num">$/month</th></tr></thead>
  <tbody>{savings()}</tbody>
  <tfoot><tr><td colspan="2">Combined → {money(t-saved)}/month</td><td class="num neg">−{money(saved)}</td></tr></tfoot>
</table>

<h2>What is not in these numbers</h2>
<table>
  <tbody>
  <tr><td>Karpenter burst capacity</td><td class="dim">Usage-driven and unbounded by design. NodePool ceilings are 160 vCPU infra, 480 app, 128 monitoring — a fully saturated infra pool would add roughly {money(40*HOURS*0.1632)}/mo on-demand, or about 43% less on spot.</td></tr>
  <tr><td>Inter-AZ data transfer</td><td class="dim">$0.01/GB each way. Cilium ENI mode gives pods real VPC IPs, so cross-AZ pod traffic is billed normally.</td></tr>
  <tr><td>Internet egress</td><td class="dim">Git clones and container pulls leaving the NLB. Highly workload-dependent.</td></tr>
  <tr><td>RDS / ElastiCache snapshots beyond the free allocation</td><td class="dim">7-day RDS backups are free up to allocated storage; 3 Redis snapshots are small.</td></tr>
  <tr><td>gp3-monitoring PVCs</td><td class="dim">The StorageClass exists but no PVC uses it yet. Prometheus + Loki at, say, 500 GiB with 6000 IOPS and 500 MB/s would add about {money(500*0.08 + 3000*0.005 + 375*0.04)}/mo.</td></tr>
  <tr><td>EKS extended support</td><td class="dim">$0.60/hr instead of $0.10 once 1.35 leaves standard support on 2027-03-27 — that is a {money(HOURS*0.50)}/mo cliff if you do not upgrade.</td></tr>
  </tbody>
</table>

</div></div>
<div id="tip" role="status"></div>
<script>
  const tip = document.getElementById('tip');
  const show = (ev, el) => {{
    tip.textContent = el.dataset.tip;
    tip.style.opacity = 1;
    const r = tip.getBoundingClientRect();
    const x = (ev.clientX ?? el.getBoundingClientRect().right) + 14;
    const y = (ev.clientY ?? el.getBoundingClientRect().top) + 14;
    tip.style.left = Math.min(x, innerWidth  - r.width  - 12) + 'px';
    tip.style.top  = Math.min(y, innerHeight - r.height - 12) + 'px';
  }};
  for (const el of document.querySelectorAll('.bar')) {{
    el.addEventListener('mousemove', ev => show(ev, el));
    el.addEventListener('focus',     ev => show(ev, el));
    el.addEventListener('mouseleave', () => tip.style.opacity = 0);
    el.addEventListener('blur',       () => tip.style.opacity = 0);
  }}
</script>
</body></html>
""")
print(f"wrote {OUT}  ({OUT.stat().st_size:,} bytes)")
