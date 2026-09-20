# cost

What this Terraform costs to run, priced from the AWS Pricing API rather than
from a pricing page.

```
fetch-prices.py   re-fetch every rate from the AWS Pricing API and print it
rates.py          the rates, as a snapshot (us-east-1, fetched 2026-09-19)
model.py          quantities x rates -> line items; run it for a text report
build.py          renders ../gitlab-aws-cost-analysis.html
```

```bash
python3 model.py                  # text report
python3 build.py                  # regenerate the HTML
python3 fetch-prices.py           # verify rates.py still matches AWS
```

## Headline

| | $/month |
|---|---|
| GitLab only | **$687.51** |
| GitLab + the shared cluster it needs | **$1,002.95** |
| Everything at default variable values | **$1,716.29** |
| After the savings levers | **$1,180.48** |

Compute is 67% of the bill. Ten on-demand nodes are $1,146.68/month; every
other line item put together is $569.61.

## Keeping it honest

Quantities in `model.py` track the **defaults** in
`../terraform-karpenter-nodepools/variables.tf`. They are not read from the
Terraform, so changing `workload_node_groups`, `storage_classes`,
`gitlab_db_instance_class` or `single_nat_gateway` means editing the matching
`Item` here too.

Three line items are estimates rather than fixed rates, and are labelled as
such in the output: NAT data processing, NLB capacity units, and S3 volume.
Everything else is a published rate times a quantity the Terraform pins.

Karpenter burst is deliberately excluded — it is usage-driven and unbounded by
design. The NodePool `limits` are the ceiling, not the expectation.
