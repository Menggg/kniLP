# KinLP

**KinLP (Kinship inference for Low-Pass sequencing)** is a toolkit for pedigree simulation, SNP QC optimization, low-pass sequencing evaluation, and IBD-based kinship inference.

KinLP provides an end-to-end workflow for benchmarking kinship inference performance in low-pass whole genome sequencing (LP-WGS) datasets.

---

# Features

* SNP marker selection using GP and BF thresholds
* Founder preparation and phasing
* Ped-Sim pedigree simulation
* IBIS kinship inference
* Low-pass sequencing benchmarking
* Automated evaluation and benchmarking
* Local parallel execution
* Slurm parallel execution
* Automatic environment validation

---

# Workflow

```text
Founder VCF
      │
      ▼
SNP Selection
      │
      ▼
Ped-Sim Simulation
      │
      ▼
Simulated Relatives
      │
      ▼
Low-Pass Processing
      │
      ▼
IBIS
      │
      ▼
Evaluation
```

---

# Installation

Clone repository:

```bash
git clone https://github.com/YOUR_USERNAME/KinLP.git

cd KinLP
```

Verify installation:

```bash
bash main.sh doctor
```

Expected:

```text
doctor summary: PASS
```

---

# Directory Structure

```text
KinLP/

main.sh

run_make_def.sh
make_snp_keep_list.sh
lowpass_ibis_functions.sh
evaluate_ibis_standard.sh

bin/
resources/

examples/
```

---

# Project Initialization

Create a new project:

```bash
bash main.sh init \
    --project demo_project \
    --config demo_project/config.txt
```

Generated structure:

```text
demo_project/

config.txt

configs/

results/
tmp/
logs/
input/
```

Check configuration:

```bash
bash main.sh \
    --config demo_project/config.txt \
    doctor
```

---

# Configuration

KinLP uses plain text configuration files.

Example:

```text
PROJECT_NAME=test_project

FOUNDER_VCF=data/founders.vcf.gz

HIGH_PASS_VCF=data/highpass.vcf.gz

SNP_PANEL_LIST=data/GSA_markers.txt

THREADS=8
```

Configuration inheritance is supported:

```text
INCLUDE=../config.txt
```

Child configuration files override parent settings.

---

# Commands

## Environment Validation

Check installation:

```bash
bash main.sh doctor
```

Check resources:

```bash
bash main.sh doctor resources
```

Check low-pass workflow:

```bash
bash main.sh doctor lowpass
```

Display capability matrix:

```bash
bash main.sh doctor capabilities
```

---

## SNP Selection

Generate SNP marker list:

```bash
bash main.sh snps
```

Example configuration:

```text
SNP_INPUT=founders.vcf.gz

SNP_GP=0.99
SNP_BF=50

SNP_ID_STYLE=chr
```

Output:

```text
snps.GP099_BF50.txt
```

Common thresholds:

| GP   | BF  |
| ---- | --- |
| 0.99 | 10  |
| 0.99 | 50  |
| 0.99 | 100 |
| 0.99 | 200 |

---

## Pedigree Definition

Generate Ped-Sim definition only:

```bash
bash main.sh def
```

Example:

```bash
bash main.sh def \
    --rel cousin \
    --degree 3
```

---

## Pedigree Simulation

Run Ped-Sim:

```bash
bash main.sh simulate
```

Example:

```bash
bash main.sh simulate \
    --rel cousin \
    --degree 3 \
    --copies 100
```

Supported relationships:

* Parent-child
* Full sibling
* Half sibling
* Avuncular
* First cousin
* Second cousin
* Third cousin
* Custom pedigrees

Outputs:

```text
.def
.vcf.gz
.seg
.ids
```

---

## Founder Preparation and Phasing

Run phasing workflow:

```bash
bash main.sh phase
```

Required inputs:

```text
HIGH_PASS_VCF

SNP_PANEL_LIST
```

Optional resources:

```text
Beagle reference panel

PLINK genetic maps
```

---

## Kinship Inference

Supported input formats:

* VCF
* BCF
* PLINK BED/BIM/FAM

Configuration:

```text
IBIS_INPUT=input.vcf.gz

IBIS_OUT_PREFIX=results/ibisOut
```

Run:

```bash
bash main.sh kinship
```

Or:

```bash
bash main.sh kinship \
    --input input.vcf.gz
```

Outputs:

```text
.raw.seg

.coef

.segcoef.tsv

.info.tsv
```

Important parameters:

```text
IBIS_MIN_L

IBIS_MT

IBIS_ER
```

---

## Low-Pass Merge

Purpose:

Merge and benchmark multiple low-pass sequencing runs against corresponding high-pass truth data.

Required configuration:

```text
HIGHPASS_PREFIX_TEMPLATE

GENOTYPE_FILE_LIST

SNP_KEEP_FILE_LIST
```

Run a single simulation:

```bash
bash main.sh lowpass-merge 1
```

Example:

```bash
bash main.sh \
    --config config.txt \
    lowpass-merge 25
```

Outputs:

* merged segment files
* merged coefficient files
* summary statistics

---

## Evaluation

Compare two standardized IBIS result collections.

Supported source types:

```text
kinship

lowpass-merge
```

Configuration:

```text
EVAL_TRUTH_TYPE=kinship
EVAL_TRUTH=results/truth

EVAL_PRED_TYPE=lowpass-merge
EVAL_PRED=results/lowpass_merge

EVAL_OUT_PREFIX=results/evaluate/run1
```

Run:

```bash
bash main.sh evaluate
```

Outputs:

```text
run1.truth.normalized.tsv

run1.pred.normalized.tsv

run1.merged.ibis.tsv

run1.pair_compare.tsv

run1.summary.tsv

run1.by_group_summary.tsv
```

Metrics:

* TP
* FP
* FN
* TN
* Precision
* Recall
* FPR
* FNR
* MSE
* RMSE
* MAE

---

# Parallel Execution

## Local

```bash
bash main.sh parallel local \
    --workflow lowpass-merge \
    --array 1-100 \
    --jobs 8
```

## Slurm

```bash
bash main.sh parallel slurm \
    --workflow lowpass-merge \
    --array 1-100
```

Check status:

```bash
bash main.sh parallel status \
    --workflow lowpass-merge \
    --array 1-100
```

---

# Example Workflow

Generate SNP list:

```bash
bash main.sh snps
```

Run simulation:

```bash
bash main.sh simulate
```

Run kinship inference:

```bash
bash main.sh kinship
```

Evaluate results:

```bash
bash main.sh evaluate
```

Complete workflow:

```text
snps
 ↓
simulate
 ↓
kinship
 ↓
evaluate
```

---

# Troubleshooting

## Missing GP

Verify that GP fields exist in the VCF.

## Missing RAF

Verify allele frequency annotations.

## Ped-Sim Errors

Check:

```text
PEDSIM_MAP

PEDSIM_INTF
```

## IBIS Errors

Check:

```text
IBIS_BIN

IBIS_MAP_FILE
```

## Lowpass-Merge Errors

Run:

```bash
bash main.sh doctor lowpass
```

## Evaluation Errors

Verify:

```text
truth source

pred source

pair matching
```

---

# Citation

If you use KinLP in published work, please cite:

```text
Wang et al.

KinLP:
A toolkit for kinship inference and benchmarking using low-pass sequencing data.
```

