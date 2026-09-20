"""Live AWS rates, us-east-1, on-demand. Refresh with fetch-prices.py.

Every number here came from the AWS Pricing API rather than a pricing page, so
it can be re-verified. Fetched 2026-09-19.
"""
HOURS = 730  # billing month

RATES = {
    "eks.cluster":      (0.10,   "hr",        "EKS cluster usage"),
    "m7g.large":        (0.0816, "hr",        "EC2 on-demand Linux"),
    "m7g.xlarge":       (0.1632, "hr",        "EC2 on-demand Linux"),
    "r7g.xlarge":       (0.2142, "hr",        "EC2 on-demand Linux"),
    "rds.m7g.large":    (0.168,  "hr",        "RDS PostgreSQL Single-AZ"),
    "rds.gp3":          (0.115,  "GB-mo",     "RDS gp3 storage"),
    "cache.m7g.large":  (0.158,  "hr",        "ElastiCache Redis"),
    "ebs.gp3.storage":  (0.08,   "GB-mo",     "EBS gp3"),
    "ebs.gp3.iops":     (0.005,  "IOPS-mo",   "EBS gp3, above 3000 free"),
    # The Pricing API quotes this as 40.96/GiBps-mo, which is the same number
    # (40.96 / 1024). Stated per MiB/s here because that is the unit the
    # StorageClass `throughput` parameter uses.
    "ebs.gp3.tput":     (0.04,   "MiBps-mo",  "EBS gp3, above 125 free"),
    "nat.hour":         (0.045,  "hr",        "NAT Gateway"),
    "nat.gb":           (0.045,  "GB",        "NAT data processing"),
    "nlb.hour":         (0.0225, "hr",        "Network Load Balancer"),
    "nlb.lcu":          (0.006,  "LCU-hr",    "NLB capacity unit"),
    "s3.standard":      (0.023,  "GB-mo",     "S3 Standard, first 50 TB"),
    "route53.zone":     (0.50,   "zone-mo",   "Hosted zone, first 25"),
    "cwlogs.ingest":    (0.50,   "GB",        "CloudWatch Logs, Standard class"),
}

# 1-year Savings Plan / Reserved Instance effective hourly rates.
COMMITTED_1YR = {
    "m7g.large": 0.0540, "m7g.xlarge": 0.1080, "r7g.xlarge": 0.1417,
    "rds.m7g.large": 0.1297, "cache.m7g.large": 0.1070,
}

# 24h trailing average spot, us-east-1, Linux.
SPOT = {"m7g.large": 0.0496, "m7g.xlarge": 0.0932, "c7g.2xlarge": 0.1274}

def r(k): return RATES[k][0]
