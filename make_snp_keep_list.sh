#!/usr/bin/env bash
set -euo pipefail

########################################
# make_snp_keep_list.sh
#
# Standalone SNP keep-list generator for PLINK / IBIS workflows.
#
# Main functions:
#   1. Generate SNP keep list from VCF/VCF.GZ/BCF using FORMAT/GP + INFO/RAF BF filtering.
#   2. Merge multiple generated or existing SNP lists by union / intersection / min-count.
#   3. Output one-column SNP IDs that can be used directly by PLINK/PLINK2 --extract.
#
# BF logic follows the user's original awk pipeline:
#   - read INFO/RAF and FORMAT/GP
#   - choose genotype with max GP
#   - compute BF = posterior odds / prior odds for that genotype
#   - keep site if maxGP > GP_threshold and BF > BF_threshold
#
# Supported VCF ID output styles:
#   --id-style vcf    : CHROM:POS as in VCF
#   --id-style chr    : force chr prefix, e.g. chr1:12345
#   --id-style nochr  : remove chr prefix, e.g. 1:12345
########################################

VERSION="2026-05-12"

########################################
# Defaults
########################################

OUT_DIR="results"
OUT_FILE=""
STATS_FILE=""
WORK_DIR=""
KEEP_WORK=1

BCFTOOLS="bcftools"
THREADS=4

INPUTS=()
INPUT_LIST=""
REGION=""

EXISTING_LISTS=()
EXISTING_LIST_FILE=""

GP_THRESHOLD="0.99"
BF_THRESHOLD="50"
INFO_AF_TAG="RAF"
FORMAT_GP_TAG="GP"
MAX_GP_CAP="0.9999"

ID_STYLE="nochr"
SAMPLE_MODE="any"   # any, all, first
SAMPLE_ID=""

MERGE_MODE="union"  # union, intersect, min-count
MIN_PASS_FILES=""

OUT_FORMAT="plink"  # currently plink one-column; tsv also supported for chr:pos IDs

########################################
# Helpers
########################################

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*" >&2
}

warn() {
    echo "[WARN] $*" >&2
}

check_file() {
    local f="$1"
    [[ -s "$f" ]] || die "missing or empty file: $f"
}

check_cmd_or_exe() {
    local x="$1"
    if [[ "$x" == */* ]]; then
        [[ -x "$x" ]] || die "not executable: $x"
    else
        command -v "$x" >/dev/null 2>&1 || die "command not found in PATH: $x"
    fi
}

safe_tag() {
    basename "$1" | sed 's/\.vcf\.gz$//; s/\.bcf$//; s/\.vcf$//; s/[^A-Za-z0-9._-]/_/g'
}

validate_number() {
    local x="$1"
    local name="$2"
    awk -v x="$x" 'BEGIN{exit !(x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/)}' \
        || die "$name must be numeric: $x"
}

validate_positive_int() {
    local x="$1"
    local name="$2"
    [[ "$x" =~ ^[0-9]+$ && "$x" -ge 1 ]] || die "$name must be a positive integer: $x"
}

validate_choices() {
    local x="$1"
    local name="$2"
    shift 2
    local ok=0
    local v
    for v in "$@"; do
        [[ "$x" == "$v" ]] && ok=1
    done
    [[ "$ok" == 1 ]] || die "$name must be one of: $*. Current: $x"
}

format_threshold_tag() {
    echo "$1" | sed 's/\.//g; s/-/m/g; s/+//g'
}

usage() {
    cat <<'USAGE'
Usage:
  make_snp_keep_list.sh [options]

Generate SNP keep list from VCF/BCF using GP/BF filtering:
  bash make_snp_keep_list.sh \
    --input sample.vcf.gz \
    --gp 0.99 \
    --bf 50 \
    --id-style nochr \
    --out results/sample.GP099.BF50.snps.txt

Multiple VCF/BCF inputs and merge:
  bash make_snp_keep_list.sh \
    --input-list vcf_files.list \
    --gp 0.99 \
    --bf 50 \
    --merge-mode union \
    --out results/merged.snps.txt

Merge existing SNP lists:
  bash make_snp_keep_list.sh \
    --merge-list GSA_hg38_snp_ID2.list \
    --merge-list sample.GP099.BF50.snps.txt \
    --merge-mode intersect \
    --out results/GSA_GP099_BF50.intersect.snps.txt

Input options:
  --input FILE                 VCF/VCF.GZ/BCF input. Can be repeated.
  --input-list FILE            List of inputs. Format: [label] file OR one file per line.
  --region REGION              Optional bcftools region, e.g. chr1 or 1.
  --chr CHR                    Alias for --region. Example: --chr 1 becomes region 1 unless input uses chr1.
                                Prefer --region when you know the chromosome style.

Filtering options:
  --gp FLOAT                   GP threshold. Default: 0.99
  --bf FLOAT                   BF threshold. Default: 50
  --info-af-tag TAG            INFO allele-frequency tag. Default: RAF
  --format-gp-tag TAG          FORMAT genotype-probability tag. Default: GP
  --max-gp-cap FLOAT           Replace GP=1 with this value to avoid division by zero. Default: 0.9999

Sample handling for multi-sample VCF/BCF:
  --sample SAMPLE_ID           Filter using only this sample.
  --sample-mode any            Keep site if any sample passes. Default.
  --sample-mode all            Keep site only if all samples pass.
  --sample-mode first          Keep site if first sample passes.

SNP ID output style:
  --id-style vcf               Output CHROM:POS using VCF CHROM exactly.
  --id-style chr               Force chr prefix, e.g. chr1:12345.
  --id-style nochr             Remove chr prefix, e.g. 1:12345. Default.

Merge existing SNP lists:
  --merge-list FILE            Existing SNP list to merge. Can be repeated.
  --merge-list-file FILE       File containing existing SNP list paths. Format: [label] file OR one file per line.
  --merge-mode union           Union of all lists. Default.
  --merge-mode intersect       SNPs present in every input/list.
  --merge-mode min-count       SNPs present in at least --min-pass-files lists.
  --min-pass-files N           Required for --merge-mode min-count.

Output options:
  --out FILE                   Output SNP list. Default auto under results/snp_lists/.
  --stats FILE                 Output summary stats TSV. Default: <out>.stats.tsv
  --out-dir DIR                Default output root. Default: results
  --work-dir DIR               Working directory. Default auto under results/snp_list_work/.
  --keep-work                  Keep intermediate per-input lists. Default.
  --clean-work                 Remove working directory after successful run.
  --out-format plink           One-column PLINK --extract list. Default.
  --out-format tsv             Three columns: snp_id chrom pos. Only valid for chr:pos-style IDs.

Tools:
  --bcftools PATH              bcftools command/path. Default: bcftools
  --threads N                  bcftools threads. Default: 4

Other:
  --help                       Show this help.

Notes:
  - Output is intended for PLINK/PLINK2 --extract and downstream IBIS/kinship workflows.
  - For PLINK data made with --set-all-var-ids '@:#', use --id-style nochr when CHROM has no chr prefix,
    or --id-style chr when PLINK IDs are chr1:pos.
USAGE
}

########################################
# Argument parsing
########################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            [[ $# -ge 2 ]] || die "--input requires FILE"
            INPUTS+=("$2")
            shift 2
            ;;
        --input-list)
            [[ $# -ge 2 ]] || die "--input-list requires FILE"
            INPUT_LIST="$2"
            shift 2
            ;;
        --region)
            [[ $# -ge 2 ]] || die "--region requires REGION"
            REGION="$2"
            shift 2
            ;;
        --chr)
            [[ $# -ge 2 ]] || die "--chr requires CHR"
            REGION="$2"
            shift 2
            ;;
        --gp)
            [[ $# -ge 2 ]] || die "--gp requires FLOAT"
            GP_THRESHOLD="$2"
            shift 2
            ;;
        --bf)
            [[ $# -ge 2 ]] || die "--bf requires FLOAT"
            BF_THRESHOLD="$2"
            shift 2
            ;;
        --info-af-tag)
            [[ $# -ge 2 ]] || die "--info-af-tag requires TAG"
            INFO_AF_TAG="$2"
            shift 2
            ;;
        --format-gp-tag)
            [[ $# -ge 2 ]] || die "--format-gp-tag requires TAG"
            FORMAT_GP_TAG="$2"
            shift 2
            ;;
        --max-gp-cap)
            [[ $# -ge 2 ]] || die "--max-gp-cap requires FLOAT"
            MAX_GP_CAP="$2"
            shift 2
            ;;
        --sample)
            [[ $# -ge 2 ]] || die "--sample requires SAMPLE_ID"
            SAMPLE_ID="$2"
            shift 2
            ;;
        --sample-mode)
            [[ $# -ge 2 ]] || die "--sample-mode requires any|all|first"
            SAMPLE_MODE="$2"
            shift 2
            ;;
        --id-style)
            [[ $# -ge 2 ]] || die "--id-style requires vcf|chr|nochr"
            ID_STYLE="$2"
            shift 2
            ;;
        --merge-list)
            [[ $# -ge 2 ]] || die "--merge-list requires FILE"
            EXISTING_LISTS+=("$2")
            shift 2
            ;;
        --merge-list-file)
            [[ $# -ge 2 ]] || die "--merge-list-file requires FILE"
            EXISTING_LIST_FILE="$2"
            shift 2
            ;;
        --merge-mode)
            [[ $# -ge 2 ]] || die "--merge-mode requires union|intersect|min-count"
            MERGE_MODE="$2"
            shift 2
            ;;
        --min-pass-files)
            [[ $# -ge 2 ]] || die "--min-pass-files requires N"
            MIN_PASS_FILES="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || die "--out requires FILE"
            OUT_FILE="$2"
            shift 2
            ;;
        --stats)
            [[ $# -ge 2 ]] || die "--stats requires FILE"
            STATS_FILE="$2"
            shift 2
            ;;
        --out-dir)
            [[ $# -ge 2 ]] || die "--out-dir requires DIR"
            OUT_DIR="$2"
            shift 2
            ;;
        --work-dir)
            [[ $# -ge 2 ]] || die "--work-dir requires DIR"
            WORK_DIR="$2"
            shift 2
            ;;
        --keep-work)
            KEEP_WORK=1
            shift
            ;;
        --clean-work)
            KEEP_WORK=0
            shift
            ;;
        --out-format)
            [[ $# -ge 2 ]] || die "--out-format requires plink|tsv"
            OUT_FORMAT="$2"
            shift 2
            ;;
        --bcftools)
            [[ $# -ge 2 ]] || die "--bcftools requires PATH"
            BCFTOOLS="$2"
            shift 2
            ;;
        --threads)
            [[ $# -ge 2 ]] || die "--threads requires N"
            THREADS="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

########################################
# Validation and setup
########################################

validate_number "$GP_THRESHOLD" "--gp"
validate_number "$BF_THRESHOLD" "--bf"
validate_number "$MAX_GP_CAP" "--max-gp-cap"
validate_positive_int "$THREADS" "--threads"
validate_choices "$ID_STYLE" "--id-style" vcf chr nochr
validate_choices "$SAMPLE_MODE" "--sample-mode" any all first
validate_choices "$MERGE_MODE" "--merge-mode" union intersect min-count
validate_choices "$OUT_FORMAT" "--out-format" plink tsv

if [[ "$MERGE_MODE" == "min-count" ]]; then
    [[ -n "$MIN_PASS_FILES" ]] || die "--min-pass-files is required when --merge-mode min-count"
    validate_positive_int "$MIN_PASS_FILES" "--min-pass-files"
fi

check_cmd_or_exe "$BCFTOOLS"

mkdir -p "$OUT_DIR"

if [[ -z "$OUT_FILE" ]]; then
    gp_tag=$(format_threshold_tag "$GP_THRESHOLD")
    bf_tag=$(format_threshold_tag "$BF_THRESHOLD")
    mkdir -p "$OUT_DIR/snp_lists"
    OUT_FILE="$OUT_DIR/snp_lists/snp_keep.GP${gp_tag}.BF${bf_tag}.${ID_STYLE}.${MERGE_MODE}.txt"
fi

if [[ -z "$STATS_FILE" ]]; then
    STATS_FILE="${OUT_FILE}.stats.tsv"
fi

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$OUT_DIR/snp_list_work/$(date +%Y%m%d_%H%M%S)_$$"
fi

mkdir -p "$(dirname "$OUT_FILE")" "$(dirname "$STATS_FILE")" "$WORK_DIR"

########################################
# Input list readers
########################################

read_input_list() {
    local list_file="$1"
    local out_file="$2"

    check_file "$list_file"

    awk '
        BEGIN{FS="[ \t]+"; OFS="\t"}
        NF == 0 {next}
        $1 ~ /^#/ {next}
        NF == 1 {print "input" NR, $1; next}
        NF >= 2 {print $1, $2; next}
    ' "$list_file" > "$out_file"

    [[ -s "$out_file" ]] || die "no valid input rows in: $list_file"
}

read_existing_list_file() {
    local list_file="$1"
    local out_file="$2"

    check_file "$list_file"

    awk '
        BEGIN{FS="[ \t]+"; OFS="\t"}
        NF == 0 {next}
        $1 ~ /^#/ {next}
        NF == 1 {print "list" NR, $1; next}
        NF >= 2 {print $1, $2; next}
    ' "$list_file" > "$out_file"

    [[ -s "$out_file" ]] || die "no valid list rows in: $list_file"
}

########################################
# SNP filtering from VCF/BCF
########################################

filter_one_vcf_by_gp_bf() {
    local label="$1"
    local input="$2"
    local out_list="$3"
    local out_stats="$4"

    check_file "$input"

    local cmd=("$BCFTOOLS" view --threads "$THREADS")

    if [[ -n "$SAMPLE_ID" ]]; then
        cmd+=(-s "$SAMPLE_ID")
    fi

    if [[ -n "$REGION" ]]; then
        cmd+=(-r "$REGION")
    fi

    cmd+=("$input")

    info "filtering input=$input label=$label"
    info "command: ${cmd[*]}"

    "${cmd[@]}" | awk \
        -v gp_thr="$GP_THRESHOLD" \
        -v bf_thr="$BF_THRESHOLD" \
        -v af_tag="$INFO_AF_TAG" \
        -v gp_tag="$FORMAT_GP_TAG" \
        -v cap="$MAX_GP_CAP" \
        -v id_style="$ID_STYLE" \
        -v sample_mode="$SAMPLE_MODE" \
        -v label="$label" \
        -v input_file="$input" \
        -v stats_file="$out_stats" '
        BEGIN {
            FS="\t"
            OFS="\t"
            total_sites=0
            sites_with_af=0
            sites_with_gp=0
            passed_sites=0
            n_samples=0
        }

        function clean_chr(c) {
            gsub(/^chrchr/, "chr", c)
            return c
        }

        function make_id(chrom, pos,    c) {
            c = clean_chr(chrom)
            if (id_style == "chr") {
                if (c !~ /^chr/) c = "chr" c
                gsub(/^chrchr/, "chr", c)
            } else if (id_style == "nochr") {
                sub(/^chr/, "", c)
            }
            return c ":" pos
        }

        function get_info_value(info, tag,    n, arr, i, key, val) {
            n = split(info, arr, ";")
            for (i=1; i<=n; i++) {
                split(arr[i], kv, "=")
                key = kv[1]
                val = kv[2]
                if (key == tag) return val
            }
            return ""
        }

        function get_format_index(fmt, tag,    n, arr, i) {
            n = split(fmt, arr, ":")
            for (i=1; i<=n; i++) {
                if (arr[i] == tag) return i
            }
            return 0
        }

        function valid_num(x) {
            return (x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/)
        }

        function cap_gp(x) {
            if (!valid_num(x)) return ""
            x += 0
            if (x >= 1) x = cap + 0
            if (x < 0) x = 0
            return x
        }

        function calc_bf(gp, geno_index, raf,    prior, post_odds, prior_odds) {
            if (gp <= 0 || gp >= 1) return 0
            if (raf <= 0 || raf >= 1) return 0

            if (geno_index == 1) {
                prior = raf * raf
            } else if (geno_index == 2) {
                prior = 2 * (1 - raf) * raf
            } else if (geno_index == 3) {
                prior = (1 - raf) * (1 - raf)
            } else {
                return 0
            }

            if (prior <= 0 || prior >= 1) return 0

            post_odds = gp / (1 - gp)
            prior_odds = prior / (1 - prior)
            if (prior_odds <= 0) return 0
            return post_odds / prior_odds
        }

        function sample_pass(sample_field, gp_idx, raf,    vals, gpstr, g, gp, maxgp, maxidx, bf) {
            split(sample_field, vals, ":")
            gpstr = vals[gp_idx]

            if (gpstr == "" || gpstr == ".") return 0

            ng = split(gpstr, g, ",")
            if (ng < 3) return 0

            g[1] = cap_gp(g[1])
            g[2] = cap_gp(g[2])
            g[3] = cap_gp(g[3])

            if (g[1] == "" || g[2] == "" || g[3] == "") return 0

            maxgp = g[1] + 0
            maxidx = 1
            if ((g[2] + 0) > maxgp) {maxgp = g[2] + 0; maxidx = 2}
            if ((g[3] + 0) > maxgp) {maxgp = g[3] + 0; maxidx = 3}

            bf = calc_bf(maxgp, maxidx, raf)

            if (maxgp > gp_thr && bf > bf_thr) return 1
            return 0
        }

        /^##/ {next}

        /^#CHROM/ {
            n_samples = NF - 9
            next
        }

        NF == 0 || /^#/ {next}

        {
            total_sites++

            chrom = $1
            pos = $2
            info = $8
            fmt = $9

            af_val = get_info_value(info, af_tag)
            if (af_val == "") next
            split(af_val, af_arr, ",")
            raf = af_arr[1] + 0
            if (raf <= 0 || raf >= 1) next
            sites_with_af++

            gp_idx = get_format_index(fmt, gp_tag)
            if (gp_idx <= 0) next
            sites_with_gp++

            if (NF < 10) next

            pass_count = 0
            checked_count = 0

            if (sample_mode == "first") {
                checked_count = 1
                if (sample_pass($10, gp_idx, raf)) pass_count = 1
            } else {
                for (i=10; i<=NF; i++) {
                    checked_count++
                    if (sample_pass($i, gp_idx, raf)) pass_count++
                }
            }

            keep = 0
            if (sample_mode == "any") {
                if (pass_count >= 1) keep = 1
            } else if (sample_mode == "all") {
                if (checked_count > 0 && pass_count == checked_count) keep = 1
            } else if (sample_mode == "first") {
                if (pass_count == 1) keep = 1
            }

            if (keep) {
                print make_id(chrom, pos)
                passed_sites++
            }
        }

        END {
            print "label", "input_file", "total_sites", "sites_with_af", "sites_with_gp", "passed_sites", "gp_threshold", "bf_threshold", "sample_mode", "id_style" > stats_file
            print label, input_file, total_sites, sites_with_af, sites_with_gp, passed_sites, gp_thr, bf_thr, sample_mode, id_style >> stats_file
        }
    ' | sort -u > "$out_list"

    info "SNPs passed for $label: $(wc -l < "$out_list" | awk '{print $1}')"
}

########################################
# Merge lists
########################################

normalize_one_list() {
    local in_list="$1"
    local out_list="$2"

    check_file "$in_list"

    awk '
        BEGIN{FS="[ \t]+"}
        NF == 0 {next}
        $1 ~ /^#/ {next}
        {print $1}
    ' "$in_list" | sort -u > "$out_list"
}

merge_lists() {
    local manifest="$1"
    local out_file="$2"
    local norm_manifest="$WORK_DIR/normalized_lists.manifest.tsv"

    : > "$norm_manifest"

    local idx=0
    local label list norm

    while IFS=$'\t' read -r label list; do
        [[ -n "$list" ]] || continue
        idx=$((idx + 1))
        norm="$WORK_DIR/norm_${idx}_$(safe_tag "$label").txt"
        normalize_one_list "$list" "$norm"
        echo -e "${label}\t${norm}" >> "$norm_manifest"
    done < "$manifest"

    local n_lists
    n_lists=$(wc -l < "$norm_manifest" | awk '{print $1}')
    [[ "$n_lists" -ge 1 ]] || die "no SNP lists to merge"

    info "merging SNP lists: n_lists=$n_lists mode=$MERGE_MODE"

    if [[ "$MERGE_MODE" == "union" ]]; then
        cut -f2 "$norm_manifest" | while read -r f; do cat "$f"; done | sort -u > "$out_file"

    elif [[ "$MERGE_MODE" == "intersect" ]]; then
        awk -v total="$n_lists" '
            BEGIN{FS="\t"}
            FNR==1 {file_index++}
            {seen[$1 SUBSEP file_index]=1; ids[$1]=1}
            END {
                for (id in ids) {
                    c=0
                    for (i=1; i<=file_index; i++) {
                        if ((id SUBSEP i) in seen) c++
                    }
                    if (c == total) print id
                }
            }
        ' $(cut -f2 "$norm_manifest") | sort -V > "$out_file"

    elif [[ "$MERGE_MODE" == "min-count" ]]; then
        awk -v minc="$MIN_PASS_FILES" '
            BEGIN{FS="\t"}
            FNR==1 {file_index++}
            {seen[$1 SUBSEP file_index]=1; ids[$1]=1}
            END {
                for (id in ids) {
                    c=0
                    for (i=1; i<=file_index; i++) {
                        if ((id SUBSEP i) in seen) c++
                    }
                    if (c >= minc) print id
                }
            }
        ' $(cut -f2 "$norm_manifest") | sort -V > "$out_file"
    else
        die "unsupported merge mode: $MERGE_MODE"
    fi
}

convert_out_format_if_needed() {
    local in_file="$1"
    local out_file="$2"

    if [[ "$OUT_FORMAT" == "plink" ]]; then
        if [[ "$in_file" != "$out_file" ]]; then
            cp "$in_file" "$out_file"
        fi
        return 0
    fi

    if [[ "$OUT_FORMAT" == "tsv" ]]; then
        awk '
            BEGIN{OFS="\t"; print "snp_id", "chrom", "pos"}
            NF == 0 {next}
            {
                id=$1
                chrom=id
                pos=id
                sub(/:[^:]+$/, "", chrom)
                sub(/^.*:/, "", pos)
                print id, chrom, pos
            }
        ' "$in_file" > "$out_file"
        return 0
    fi

    die "unsupported out format: $OUT_FORMAT"
}

########################################
# Main workflow
########################################

main() {
    info "make_snp_keep_list.sh version=$VERSION"
    info "OUT_FILE=$OUT_FILE"
    info "STATS_FILE=$STATS_FILE"
    info "WORK_DIR=$WORK_DIR"
    info "GP_THRESHOLD=$GP_THRESHOLD"
    info "BF_THRESHOLD=$BF_THRESHOLD"
    info "INFO_AF_TAG=$INFO_AF_TAG"
    info "FORMAT_GP_TAG=$FORMAT_GP_TAG"
    info "ID_STYLE=$ID_STYLE"
    info "SAMPLE_MODE=$SAMPLE_MODE"
    info "MERGE_MODE=$MERGE_MODE"

    local input_manifest="$WORK_DIR/input_manifest.tsv"
    local list_manifest="$WORK_DIR/list_manifest.tsv"
    local generated_stats_manifest="$WORK_DIR/generated_stats.list"
    local merged_raw="$WORK_DIR/merged.raw.txt"

    : > "$input_manifest"
    : > "$list_manifest"
    : > "$generated_stats_manifest"

    local f label

    # Explicit VCF/BCF inputs
    for f in "${INPUTS[@]}"; do
        check_file "$f"
        label=$(safe_tag "$f")
        echo -e "${label}\t${f}" >> "$input_manifest"
    done

    # Input-list file
    if [[ -n "$INPUT_LIST" ]]; then
        local tmp_inputs="$WORK_DIR/input_list.expanded.tsv"
        read_input_list "$INPUT_LIST" "$tmp_inputs"
        cat "$tmp_inputs" >> "$input_manifest"
    fi

    # Existing lists from repeated --merge-list
    for f in "${EXISTING_LISTS[@]}"; do
        check_file "$f"
        label=$(safe_tag "$f")
        echo -e "${label}\t${f}" >> "$list_manifest"
    done

    # Existing lists from file
    if [[ -n "$EXISTING_LIST_FILE" ]]; then
        local tmp_lists="$WORK_DIR/existing_list.expanded.tsv"
        read_existing_list_file "$EXISTING_LIST_FILE" "$tmp_lists"
        cat "$tmp_lists" >> "$list_manifest"
    fi

    # Generate per-input lists from VCF/BCF
    local idx=0
    local in_file out_one stats_one
    while IFS=$'\t' read -r label in_file; do
        [[ -n "$in_file" ]] || continue
        idx=$((idx + 1))
        out_one="$WORK_DIR/generated_${idx}_$(safe_tag "$label").snps.txt"
        stats_one="$WORK_DIR/generated_${idx}_$(safe_tag "$label").stats.tsv"
        filter_one_vcf_by_gp_bf "$label" "$in_file" "$out_one" "$stats_one"
        echo -e "${label}\t${out_one}" >> "$list_manifest"
        echo "$stats_one" >> "$generated_stats_manifest"
    done < "$input_manifest"

    [[ -s "$list_manifest" ]] || die "no inputs provided. Use --input/--input-list and/or --merge-list/--merge-list-file"

    merge_lists "$list_manifest" "$merged_raw"
    convert_out_format_if_needed "$merged_raw" "$OUT_FILE"

    # Write final stats
    {
        echo -e "section\tkey\tvalue"
        echo -e "summary\toutput\t${OUT_FILE}"
        echo -e "summary\tn_snps\t$(awk 'NF>0 && $1 !~ /^#/ && $1 != \"snp_id\" {c++} END{print c+0}' "$OUT_FILE")"
        echo -e "summary\tgp_threshold\t${GP_THRESHOLD}"
        echo -e "summary\tbf_threshold\t${BF_THRESHOLD}"
        echo -e "summary\tinfo_af_tag\t${INFO_AF_TAG}"
        echo -e "summary\tformat_gp_tag\t${FORMAT_GP_TAG}"
        echo -e "summary\tid_style\t${ID_STYLE}"
        echo -e "summary\tsample_mode\t${SAMPLE_MODE}"
        echo -e "summary\tsample\t${SAMPLE_ID:-all_or_mode_based}"
        echo -e "summary\tmerge_mode\t${MERGE_MODE}"
        echo -e "summary\tmin_pass_files\t${MIN_PASS_FILES:-NA}"
        echo -e "summary\tregion\t${REGION:-all}"
        echo -e "summary\twork_dir\t${WORK_DIR}"
        echo -e "summary\tlist_manifest\t${list_manifest}"
        echo -e "summary\tinput_manifest\t${input_manifest}"
    } > "$STATS_FILE"

    if [[ -s "$generated_stats_manifest" ]]; then
        {
            echo ""
            echo "# per-input GP/BF filtering stats"
            first=1
            while read -r sf; do
                [[ -s "$sf" ]] || continue
                if [[ "$first" -eq 1 ]]; then
                    cat "$sf"
                    first=0
                else
                    tail -n +2 "$sf"
                fi
            done < "$generated_stats_manifest"
        } >> "$STATS_FILE"
    fi

    info "DONE"
    info "SNP list: $OUT_FILE"
    info "N SNPs  : $(awk 'NF>0 && $1 !~ /^#/ && $1 != \"snp_id\" {c++} END{print c+0}' "$OUT_FILE")"
    info "Stats   : $STATS_FILE"

    if [[ "$KEEP_WORK" == "0" ]]; then
        rm -rf "$WORK_DIR"
        info "Work dir removed"
    else
        info "Work dir kept: $WORK_DIR"
    fi
}

main
