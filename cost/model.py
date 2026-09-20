"""The cost model: what this Terraform provisions, and what each piece costs.

Quantities track the *defaults* in terraform-karpenter-nodepools/variables.tf.
Change a default there and the matching LineItem here has to change too.
"""
from dataclasses import dataclass
from rates import RATES, HOURS, COMMITTED_1YR, SPOT, r

@dataclass
class Item:
    group: str        # "shared" | "gitlab" | "other"
    name: str
    detail: str       # the quantity, spelled out
    monthly: float
    note: str = ""    # why it costs what it does, where non-obvious

def gp3(gb, iops=3000, tput=125):
    """gp3 bills storage always; IOPS above 3000 and MiB/s above 125 are extra."""
    return (gb * r("ebs.gp3.storage")
            + max(0, iops - 3000) * r("ebs.gp3.iops")
            + max(0, tput - 125) * r("ebs.gp3.tput"))

ITEMS = [
    # ---------------- shared cluster ----------------
    Item("shared", "EKS control plane", "1 cluster", HOURS * r("eks.cluster"),
         "Flat. Would be $0.60/hr on a version in extended support; 1.35 is not."),
    Item("shared", "core node group", "2 x m7g.large on-demand", 2 * HOURS * r("m7g.large"),
         "Untainted tier: Cilium operator, CoreDNS, Karpenter, LBC, external-dns."),
    Item("shared", "core root volumes", "2 x 50 GiB gp3", 2 * gp3(50)),
    Item("shared", "NAT Gateways", "3, one per AZ", 3 * HOURS * r("nat.hour"),
         "single_nat_gateway = false. Dropping to 1 saves two thirds, at the cost of AZ isolation."),
    Item("shared", "NAT data processing", "~150 GB/mo egress", 150 * r("nat.gb"),
         "Estimate. Image pulls dominate; scales with how often nodes cycle."),
    Item("shared", "CloudWatch control-plane logs", "api + audit + authenticator, ~20 GB/mo",
         20 * r("cwlogs.ingest"),
         "audit is by far the largest of the three. Drop it from cluster_enabled_log_types to cut this."),

    # ---------------- GitLab ----------------
    Item("gitlab", "infra node group", "3 x m7g.xlarge on-demand", 3 * HOURS * r("m7g.xlarge"),
         "GitLab is pinned here. On-demand not spot on purpose: Gitaly is stateful."),
    Item("gitlab", "infra root volumes", "3 x 80 GiB gp3", 3 * gp3(80)),
    Item("gitlab", "RDS PostgreSQL 17", "db.m7g.large, Single-AZ", HOURS * r("rds.m7g.large"),
         "Multi-AZ roughly doubles this. Chart v10 removed bundled Postgres, so this is mandatory."),
    Item("gitlab", "RDS storage", "100 GiB gp3, autoscale to 400", 100 * r("rds.gp3"),
         "7-day backups are free up to allocated size."),
    Item("gitlab", "ElastiCache Redis", "cache.m7g.large, 1 node", HOURS * r("cache.m7g.large"),
         "Single node, no failover. Chart v10 removed bundled Redis too."),
    Item("gitlab", "Gitaly volume", "100 GiB gp3-infra, 4000 IOPS, 250 MB/s", gp3(100, 4000, 250),
         "$8 storage + $5 IOPS + $5 throughput. The provisioned headroom is the $10."),
    Item("gitlab", "Network Load Balancer", "1 internet-facing", HOURS * r("nlb.hour"),
         "Created by the AWS LBC from the Envoy Gateway Service."),
    Item("gitlab", "NLB capacity units", "~5 LCU average", 5 * HOURS * r("nlb.lcu"),
         "Estimate. Scales with concurrent connections and bandwidth - git clones are bursty."),
    Item("gitlab", "S3 object storage", "12 buckets, ~200 GB total", 200 * r("s3.standard"),
         "Artifacts, LFS, uploads, packages, registry, backups. Grows with CI retention."),
    Item("gitlab", "Route53 hosted zone", "1 public zone", r("route53.zone")),

    # ---------------- other tiers ----------------
    Item("other", "app node group", "3 x m7g.xlarge on-demand", 3 * HOURS * r("m7g.xlarge")),
    Item("other", "app root volumes", "3 x 80 GiB gp3", 3 * gp3(80)),
    Item("other", "monitoring node group", "2 x r7g.xlarge on-demand", 2 * HOURS * r("r7g.xlarge"),
         "Memory-biased for Prometheus and Loki."),
    Item("other", "monitoring root volumes", "2 x 150 GiB gp3", 2 * gp3(150)),
]

GROUPS = {
    "gitlab": ("GitLab", "Provisioned only when enable_gitlab = true"),
    "shared": ("Shared cluster", "Needed whether or not GitLab is installed"),
    "other":  ("app + monitoring tiers", "Capacity floors for everything else"),
}

def subtotal(g): return sum(i.monthly for i in ITEMS if i.group == g)
def total():     return sum(i.monthly for i in ITEMS)

SAVINGS = [
    ("1-year Compute Savings Plan on all 10 nodes",
     sum(n * HOURS * (r(t) - COMMITTED_1YR[t]) for n, t in
         [(2, "m7g.large"), (3, "m7g.xlarge"), (3, "m7g.xlarge"), (2, "r7g.xlarge")]),
     "No architectural change. Largest single lever by a wide margin."),
    ("single_nat_gateway = true", 2 * HOURS * r("nat.hour"),
     "Loses per-AZ isolation: one AZ's NAT failure takes egress down cluster-wide."),
    ("1-year RI on RDS + ElastiCache",
     HOURS * ((r("rds.m7g.large") - COMMITTED_1YR["rds.m7g.large"])
              + (r("cache.m7g.large") - COMMITTED_1YR["cache.m7g.large"])),
     "Same caveat as the Savings Plan: a 1-year commitment."),
    ("Drop the audit control-plane log type", 14 * r("cwlogs.ingest"),
     "Only if you have no compliance requirement for it."),
    ("Gitaly at gp3 baseline IOPS/throughput", gp3(100, 4000, 250) - gp3(100),
     "Measure first. If Gitaly is not IO-bound the provisioned headroom is wasted."),
]

if __name__ == "__main__":
    for g, (label, _) in GROUPS.items():
        print(f"\n## {label}")
        for i in [x for x in ITEMS if x.group == g]:
            print(f"  {i.name:30s} {i.detail:38s} ${i.monthly:8,.2f}")
        print(f"  {'':30s} {'SUBTOTAL':38s} ${subtotal(g):8,.2f}")
    print(f"\n  {'TOTAL / month':69s} ${total():8,.2f}")
    print(f"  {'TOTAL / year':69s} ${total()*12:8,.2f}")
    print(f"\n  GitLab alone      ${subtotal('gitlab'):8,.2f}/mo")
    print(f"  GitLab + shared   ${subtotal('gitlab')+subtotal('shared'):8,.2f}/mo")
    print("\n## Savings")
    for n, v, _ in SAVINGS: print(f"  {n:48s} -${v:7,.2f}/mo")
    print(f"  {'combined':48s} -${sum(v for _,v,_ in SAVINGS):7,.2f}/mo "
          f"-> ${total()-sum(v for _,v,_ in SAVINGS):,.2f}/mo")
