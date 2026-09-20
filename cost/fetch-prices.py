#!/usr/bin/env python3
"""Re-fetch every rate in rates.py from the AWS Pricing API.

Run this instead of trusting the numbers in rates.py, which are a snapshot.
Needs pricing:GetProducts (the Pricing API lives in us-east-1 regardless of
which region you are costing).

    python3 fetch-prices.py
"""
import json, subprocess, sys

LOC = ("location", "US East (N. Virginia)")

def products(service, filters, mr=100):
    args = ["aws", "pricing", "get-products", "--region", "us-east-1",
            "--service-code", service, "--max-results", str(mr), "--output", "json",
            "--filters"] + [f"Type=TERM_MATCH,Field={k},Value={v}" for k, v in filters]
    out = subprocess.run(args, capture_output=True, text=True)
    if out.returncode:
        print(f"  ! {service}: {out.stderr.strip().splitlines()[-1:]}", file=sys.stderr)
        return []
    return [json.loads(p) for p in json.loads(out.stdout)["PriceList"]]

def on_demand(p):
    for t in p["terms"].get("OnDemand", {}).values():
        for d in t["priceDimensions"].values():
            yield float(d["pricePerUnit"]["USD"]), d["unit"], d["description"]

def reserved(p, years, option="No Upfront", cls="standard"):
    for t in p["terms"].get("Reserved", {}).values():
        a = t["termAttributes"]
        if (a.get("LeaseContractLength") == f"{years}yr"
                and a.get("PurchaseOption") == option and a.get("OfferingClass") == cls):
            for d in t["priceDimensions"].values():
                if d["unit"] == "Hrs":
                    return float(d["pricePerUnit"]["USD"])

def first(p_list, want=None):
    for p in p_list:
        for v, u, d in on_demand(p):
            if want is None or want in d:
                return p, v, u, d
    return None, None, None, None

print("EC2 on-demand / 1yr RI / 3yr RI")
for it in ["m7g.large", "m7g.xlarge", "r7g.xlarge"]:
    p, v, u, _ = first(products("AmazonEC2", [("instanceType", it), LOC,
        ("operatingSystem", "Linux"), ("tenancy", "Shared"),
        ("preInstalledSw", "NA"), ("capacitystatus", "Used")]))
    if p: print(f"  {it:14s} {v:.4f}/hr   1yr {reserved(p,1):.4f}   3yr {reserved(p,3):.4f}")

print("Managed data services")
p, v, _, _ = first(products("AmazonRDS", [("instanceType", "db.m7g.large"), LOC,
    ("databaseEngine", "PostgreSQL"), ("deploymentOption", "Single-AZ")]))
if p: print(f"  rds db.m7g.large  {v:.4f}/hr   1yr {reserved(p,1):.4f}")
_, v, _, _ = first(products("AmazonRDS", [LOC, ("volumeType", "General Purpose-GP3"),
    ("productFamily", "Database Storage")]))
print(f"  rds gp3 storage   {v:.4f}/GB-mo")
p, v, _, _ = first(products("AmazonElastiCache", [("instanceType", "cache.m7g.large"),
    LOC, ("cacheEngine", "Redis")]))
if p: print(f"  cache.m7g.large   {v:.4f}/hr   1yr {reserved(p,1):.4f}")

print("EBS gp3")
for fam, label in [("Storage", "storage  "), ("System Operation", "iops     "),
                   ("Provisioned Throughput", "throughput")]:
    _, v, u, _ = first(products("AmazonEC2", [LOC, ("productFamily", fam),
                                              ("volumeApiName", "gp3")]))
    if v is not None: print(f"  {label}        {v:.4f}/{u}")

print("Networking and fixed")
_, v, _, _ = first(products("AmazonEKS", [("usagetype", "USE1-AmazonEKS-Hours:perCluster")]))
print(f"  eks cluster       {v:.4f}/hr")
_, v, _, _ = first(products("AmazonEC2", [LOC, ("productFamily", "NAT Gateway")]),
                   "per NAT Gateway Hour")
print(f"  nat gateway       {v:.4f}/hr")
_, v, _, _ = first(products("AWSELB", [LOC, ("productFamily", "Load Balancer-Network")]),
                   "per Network LoadBalancer-hour")
print(f"  nlb               {v:.4f}/hr")
_, v, _, _ = first(products("AmazonS3", [LOC, ("productFamily", "Storage"),
                   ("volumeType", "Standard")]), "first 50 TB")
print(f"  s3 standard       {v:.4f}/GB-mo")
_, v, _, _ = first(products("AmazonRoute53", [("productFamily", "DNS Zone")]),
                   "first 25 Hosted Zones")
print(f"  route53 zone      {v:.4f}/zone-mo")

print("\nSpot, 24h trailing average")
import datetime
start = (datetime.datetime.utcnow() - datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S")
for it in ["m7g.large", "m7g.xlarge", "c7g.2xlarge"]:
    o = subprocess.run(["aws", "ec2", "describe-spot-price-history", "--instance-types", it,
        "--product-descriptions", "Linux/UNIX", "--region", "us-east-1",
        "--start-time", start, "--query", "SpotPriceHistory[].SpotPrice",
        "--output", "text"], capture_output=True, text=True)
    vals = [float(x) for x in o.stdout.split() if x]
    if vals: print(f"  {it:14s} {sum(vals)/len(vals):.4f}/hr  (n={len(vals)})")
