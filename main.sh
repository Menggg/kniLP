#!/usr/bin/env bash
set -euo pipefail

VERSION="2026-05-13-evaluate-v2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ORIGINAL_ARGS=("$@")

CONFIG_FILE="${MIXDETECT_CONFIG:-}"
NO_PREFLIGHT=0
FORCE_STAGE=""
LOCAL_SCRATCH_OVERRIDE=""

info(){ echo "[mix_detect] $*" >&2; }
warn(){ echo "[mix_detect][WARN] $*" >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }

usage(){ cat >&2 <<'USAGE'
Usage:
  bash main.sh [global options] <command> [options]

Global options:
  --config FILE          Plain KEY=VALUE config file. INCLUDE=... is supported.
  --no-preflight         Disable fast preflight for this run.
  --stage                Force task-level local scratch staging.
  --no-stage             Disable staging for this run.
  --local-scratch DIR    Local scratch root used with --stage.
  -h, --help             Show help.

Commands:
  init                         Create project config and example configs.
  config <snps|phase|simulate|kinship|workflow|parallel|evaluate>
  profile <init|list|show>     Manage ~/.mixdetect/profiles/*.txt.
  doctor [resources]           Full environment/resources check.
  doctor config <module|all>    Check loaded config runtime settings.
  snps | snplist               Generate SNP keep list.
  phase                        Run phasing/prep module.
  def                          Generate Ped-Sim .def only.
  simulate | pedsim            Generate def and run Ped-Sim.
  kinship | ibis               Run IBIS-only kinship workflow.
  lowpass-merge N              Run low-pass/high-pass merge task N directly from main.sh.
  evaluate                     Evaluate predicted kinship/IBIS output against truth.
  workflow simulate-kinship    Run snps -> simulate -> kinship.
  parallel local|slurm|task|status

Examples:
  bash main.sh --config config.txt doctor      # check whether config can run
  bash main.sh --config configs/snps.GP099_BF50.txt snps
  bash main.sh --config config.txt simulate --rel cousin --degree 3 --print-all-with-founders
  bash main.sh --config config.txt parallel local --workflow lowpass-merge --array 1-10 --jobs 4
  bash main.sh --config configs/evaluate.txt evaluate
USAGE
}

# ---------- config/profile loader for plain KEY=VALUE files ----------
_shell_quote(){ printf "%q" "$1"; }
abs_path_from(){ local base="$1" p="$2"; [[ "$p" = /* ]] && echo "$p" || echo "$(cd "$(dirname "$base")" && pwd)/$p"; }

load_plain_config(){
  local file="$1" seen="${2:-}"
  [[ -s "$file" ]] || die "config file not found or empty: $file"
  local real; real="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  [[ ":$seen:" != *":$real:"* ]] || die "circular INCLUDE detected: $real"

  local incs line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="${line#*=}"; val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$key" == "INCLUDE" && -n "$val" ]]; then
      load_plain_config "$(abs_path_from "$real" "$val")" "$seen:$real"
    fi
  done < "$real"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="${line#*=}"; val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$key" == "INCLUDE" ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad config key: $key in $real"
    printf -v "$key" '%s' "$val"
    export "$key"
  done < "$real"
}

load_all_config(){
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    load_plain_config "$CONFIG_FILE"
  fi
  if [[ -n "${PROFILE:-}" && -s "$HOME/.mixdetect/profiles/${PROFILE}.txt" ]]; then
    # profile is base; project config overrides it, so reload in order
    local cf="$CONFIG_FILE"
    load_plain_config "$HOME/.mixdetect/profiles/${PROFILE}.txt"
    [[ -n "$cf" ]] && load_plain_config "$cf"
  fi

  : "${TOOL_ROOT:=$SCRIPT_DIR}"
  : "${BIN_DIR:=$TOOL_ROOT/bin}"
  : "${RESOURCE_DIR:=$TOOL_ROOT/resources}"
  : "${PROJECT_DIR:=$PWD}"
  : "${OUT_DIR:=$PROJECT_DIR/results}"
  : "${TMP_DIR:=$PROJECT_DIR/tmp}"
  : "${LOG_DIR:=$PROJECT_DIR/logs}"
  : "${FAST_PREFLIGHT:=1}"
  : "${THREADS:=4}"

  : "${SNPLIST_SCRIPT:=$TOOL_ROOT/make_snp_keep_list.sh}"
  : "${PEDSIM_SCRIPT:=$TOOL_ROOT/run_make_def_test_with_auto_vcf_founders_map_sort_chrfix_phase_mapfix.sh}"
  : "${LOWPASS_IBIS_FUNCTIONS:=$TOOL_ROOT/lowpass_ibis_functions.sh}"
  : "${LOWPASS_MERGE_SCRIPT:=$LOWPASS_IBIS_FUNCTIONS}"

  : "${BCFTOOLS:=$BIN_DIR/bcftools}"
  : "${PLINK:=$BIN_DIR/plink}"
  : "${PLINK2:=$BIN_DIR/plink2}"
  : "${PEDSIM_BIN:=$BIN_DIR/ped-sim}"
  : "${IBIS_BIN:=$BIN_DIR/ibis}"
  : "${IBIS_ADD_MAP:=$BIN_DIR/add-map-plink.pl}"
  : "${BEAGLE_JAR:=$BIN_DIR/beagle.jar}"

  : "${PEDSIM_MAP:=$RESOURCE_DIR/refined_mf_hg38_noCHR.simmap}"
  : "${PEDSIM_INTF:=$RESOURCE_DIR/sex_av_nu_p_hg38_campbell_noCHR.tsv}"
  : "${IBIS_MAP_FILE:=$RESOURCE_DIR/genetic_map_GRCh38_merged.tab}"
  [[ -n "${PHASE_MAP_TEMPLATE:-}" ]] || PHASE_MAP_TEMPLATE="$RESOURCE_DIR/plink.chr{chr}.GRCh38.map"

  # Optional structured resource locations. These allow either the original flat
  # resources/ layout or a cleaner subdirectory layout without breaking configs.
  : "${RESOURCE_MAP_DIR:=$RESOURCE_DIR/maps}"
  : "${RESOURCE_IBIS_DIR:=$RESOURCE_DIR/ibis}"
  : "${RESOURCE_PLINK_MAP_DIR:=$RESOURCE_DIR/plink_map}"
  : "${RESOURCE_SNP_PANEL_DIR:=$RESOURCE_DIR/snp_panels}"
  : "${RESOURCE_HAP_REF_DIR:=$RESOURCE_DIR/haplotype_ref}"
  : "${RESOURCE_AF_DIR:=$RESOURCE_DIR/allele_freq}"
  : "${RESOURCE_REF_DIR:=$RESOURCE_DIR/reference}"
  : "${REQUIRE_PHASE_MAPS:=0}"
  : "${REQUIRE_HAP_REF:=0}"
  [[ -n "${HAP_REF_TEMPLATE:-}" ]] || HAP_REF_TEMPLATE="$RESOURCE_HAP_REF_DIR/chr{chr}.vcf.gz"

  : "${SNP_INPUT:=${FOUNDER_VCF:-}}"
  : "${SNP_GP:=0.99}"
  : "${SNP_BF:=50}"
  : "${SNP_ID_STYLE:=chr}"
  : "${SNP_SAMPLE_MODE:=any}"
  : "${SNP_OUT:=$OUT_DIR/snps.GP${SNP_GP/./}_BF${SNP_BF/./}.${SNP_ID_STYLE}.txt}"

  : "${SIM_RELATIONSHIP:=${DEFAULT_RELATIONSHIP:-cousin}}"
  : "${SIM_DEGREE:=${DEFAULT_DEGREE:-3}}"
  : "${SIM_HALF:=${DEFAULT_HALF:-0}}"
  : "${SIM_COPIES:=${DEFAULT_COPIES:-1}}"
  : "${SIM_DEF_NAME:=${SIM_RELATIONSHIP}_d${SIM_DEGREE}}"
  : "${SIM_SEED:=${DEFAULT_SEED:-42}}"

  : "${IBIS_THREADS:=$THREADS}"
  : "${IBIS_MIN_L:=7}"
  : "${IBIS_MT:=0.004}"
  : "${IBIS_ER:=0.004}"
  : "${IBIS_SET_ALL_VAR_IDS:=@:#}"

  : "${STAGE_TO_LOCAL:=auto}"
  : "${LOCAL_SCRATCH_ROOT:=auto}"
  : "${LOCAL_CACHE_MODE:=task}"
  : "${STAGE_METHOD:=rsync}"
  : "${STAGE_RANDOM_SLEEP:=1}"
  : "${STAGE_RANDOM_SLEEP_MAX:=120}"
  : "${CLEAN_LOCAL_SCRATCH:=1}"
  : "${KEEP_LOCAL_ON_FAIL:=1}"
  : "${COPY_RESULTS_BACK:=1}"
  : "${STAGE_OUTPUTS_LOCAL:=1}"


  : "${EVAL_TRUTH_TYPE:=auto}"
  : "${EVAL_PRED_TYPE:=auto}"
  : "${EVAL_OUT_PREFIX:=$OUT_DIR/evaluate/run1}"
  : "${EVAL_REL_CUTOFF_CM:=0}"
  : "${EVAL_PAIR_ORDER:=sort}"

  mkdir -p "$OUT_DIR" "$TMP_DIR" "$LOG_DIR"
}

check_script(){ [[ -s "$1" ]] || die "script missing or empty: $1"; }
check_file_if_set(){ local f="${1:-}" label="${2:-file}"; [[ -z "$f" ]] || [[ -s "$f" ]] || die "$label missing or empty: $f"; }
check_exe_if_needed(){ local x="${1:-}" label="${2:-program}"; [[ -z "$x" ]] && return 0; if [[ "$x" == */* ]]; then [[ -x "$x" || -s "$x" ]] || die "$label not found/executable: $x"; else command -v "$x" >/dev/null 2>&1 || die "$label command not found: $x"; fi; }

fast_preflight(){
  local cmd="$1"
  [[ "$NO_PREFLIGHT" == 1 || "${FAST_PREFLIGHT:-1}" == 0 ]] && return 0
  [[ -d "$TOOL_ROOT" ]] || die "TOOL_ROOT not found: $TOOL_ROOT"
  mkdir -p "$OUT_DIR" "$TMP_DIR" "$LOG_DIR"
  [[ -w "$OUT_DIR" ]] || die "OUT_DIR not writable: $OUT_DIR"
  case "$cmd" in
    snps|snplist) check_script "$SNPLIST_SCRIPT"; check_file_if_set "${SNP_INPUT:-}" SNP_INPUT ;;
    phase|def|simulate|pedsim) check_script "$PEDSIM_SCRIPT" ;;
    kinship|ibis|lowpass-merge) check_script "$LOWPASS_IBIS_FUNCTIONS" ;;
    evaluate) [[ -n "${EVAL_TRUTH:-}" ]] || die "EVAL_TRUTH is required"; [[ -n "${EVAL_PRED:-}" ]] || die "EVAL_PRED is required" ;;
    workflow|parallel) : ;;
  esac
}

doctor_check_path(){
  local path="$1" label="$2" required="${3:-1}"
  if [[ -s "$path" || -x "$path" || -d "$path" ]]; then
    echo "[OK] $label=$path"
    return 0
  fi
  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label=$path"
    return 1
  fi
  echo "[WARN] $label not found: $path"
  return 0
}

first_existing(){
  local x
  for x in "$@"; do
    [[ -s "$x" || -d "$x" || -x "$x" ]] && { echo "$x"; return 0; }
  done
  return 1
}

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

path_ok(){
  local x="${1:-}" kind="${2:-any}"
  [[ -n "$x" ]] || return 1
  if [[ "$x" == */* ]]; then
    case "$kind" in
      exe) [[ -x "$x" ]] ;;
      dir) [[ -d "$x" ]] ;;
      file) [[ -s "$x" ]] ;;
      any) [[ -s "$x" || -x "$x" || -d "$x" ]] ;;
      *) [[ -s "$x" || -x "$x" || -d "$x" ]] ;;
    esac
  else
    [[ "$kind" == "exe" || "$kind" == "any" ]] && command -v "$x" >/dev/null 2>&1
  fi
}

show_path_status(){
  local label="$1" value="${2:-}" kind="${3:-any}" required="${4:-1}" hint="${5:-}"
  if path_ok "$value" "$kind"; then
    if [[ "$value" == */* || "$kind" == "dir" || "$kind" == "file" ]]; then
      echo "[OK]   $label=$value"
    else
      echo "[OK]   $label=$value -> $(command -v "$value")"
    fi
    return 0
  fi
  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label=${value:-<not set>}${hint:+  # $hint}"
    return 1
  fi
  echo "[WARN] $label=${value:-<not set>}${hint:+  # $hint}"
  return 2
}

check_template_1_22(){
  local template="$1" label="$2" required="${3:-0}" ok=1 missing=()
  local chr f
  [[ -n "$template" ]] || { echo "[MISS] $label template is empty"; return 1; }
  for chr in $(seq 1 22); do
    f="${template//\{chr\}/$chr}"
    if [[ ! -s "$f" ]]; then
      missing+=("$chr")
      ok=0
    fi
  done
  if [[ "$ok" == 1 ]]; then
    echo "[OK]   $label chr1-22 template=$template"
    return 0
  fi
  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label missing chromosomes: ${missing[*]} template=$template"
    return 1
  fi
  echo "[WARN] $label incomplete; missing chromosomes: ${missing[*]} template=$template"
  return 2
}

find_pedsim_map(){ first_existing "${PEDSIM_MAP:-}" "$RESOURCE_MAP_DIR/refined_mf_hg38_noCHR.simmap" "$RESOURCE_MAP_DIR/refined_mf_hg38_chr.simmap" "$RESOURCE_DIR/refined_mf_hg38_noCHR.simmap" "$RESOURCE_DIR/refined_mf_hg38_chr.simmap" 2>/dev/null || true; }
find_pedsim_intf(){ first_existing "${PEDSIM_INTF:-}" "$RESOURCE_MAP_DIR/sex_av_nu_p_hg38_campbell_noCHR.tsv" "$RESOURCE_MAP_DIR/sex_av_nu_p_hg38_campbell_chr.tsv" "$RESOURCE_DIR/sex_av_nu_p_hg38_campbell_noCHR.tsv" "$RESOURCE_DIR/sex_av_nu_p_hg38_campbell_chr.tsv" 2>/dev/null || true; }
find_ibis_map(){ first_existing "${IBIS_MAP_FILE:-}" "$RESOURCE_DIR/genetic_map_GRCh38_merged.tab" "$RESOURCE_IBIS_DIR/ibis.map" "$RESOURCE_DIR/ibis.map" 2>/dev/null || true; }
find_snp_panel(){
  if [[ -n "${SNP_PANEL_LIST:-}" && -s "$SNP_PANEL_LIST" ]]; then echo "$SNP_PANEL_LIST"; return 0; fi
  find "$RESOURCE_SNP_PANEL_DIR" "$RESOURCE_DIR" -maxdepth 1 -type f \( -name '*GSA*' -o -name '*snp*' -o -name '*SNP*' \) 2>/dev/null | head -n 1 || true
}

func_exists_in_file(){
  local file="$1" fname="$2"
  [[ -s "$file" ]] || return 1
  grep -Eq "^[[:space:]]*(function[[:space:]]+${fname}|${fname}[[:space:]]*\(\))" "$file"
}

expand_n_template(){
  local template="$1" n="$2"
  template="${template//\{n\}/$n}"
  template="${template//%n/$n}"
  echo "$template"
}

first_id_from_array(){
  local arr="${1:-}"
  [[ -n "$arr" ]] || { echo 1; return 0; }
  arr="${arr%%,*}"
  if [[ "$arr" == *-* ]]; then
    echo "${arr%%-*}"
  else
    echo "$arr"
  fi
}

lowpass_functions_ok(){
  func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" init_lowpass_collection && \
  func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" process_all_units_for_sim && \
  func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" collect_lowpass_units
}

count_config_list_rows(){
  local f="${1:-}"
  [[ -s "$f" ]] || { echo 0; return 0; }
  awk 'NF==0 || $1 ~ /^#/ {next} {n++} END{print n+0}' "$f"
}

check_config_list_file(){
  local label="$1" f="${2:-}" required="${3:-1}" max_check="${4:-5}"
  local ok=1 n=0 missing=0 checked=0 path=""
  if [[ -z "$f" ]]; then
    if [[ "$required" == 1 ]]; then echo "[MISS] $label not set"; return 1; fi
    echo "[SKIP] $label not set"; return 0
  fi
  if [[ ! -s "$f" ]]; then
    echo "[MISS] $label file missing or empty: $f"
    return 1
  fi
  n=$(count_config_list_rows "$f")
  echo "[OK]   $label=$f rows=$n"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    checked=$((checked+1))
    if [[ ! -s "$path" && ! -e "$path" ]]; then
      echo "[MISS] $label referenced file missing: $path"
      missing=$((missing+1)); ok=0
    fi
    [[ "$checked" -ge "$max_check" ]] && break
  done < <(awk 'NF==0 || $1 ~ /^#/ {next} {print $NF}' "$f")
  if [[ "$checked" -gt 0 && "$missing" == 0 ]]; then
    echo "[OK]   $label first $checked referenced paths exist"
  fi
  [[ "$ok" == 1 ]] && return 0 || return 1
}

check_plink_prefix(){
  local label="$1" prefix="${2:-}" required="${3:-1}"
  if [[ -z "$prefix" ]]; then
    if [[ "$required" == 1 ]]; then echo "[MISS] $label prefix is empty"; return 1; fi
    echo "[SKIP] $label prefix is empty"; return 0
  fi
  local ok=1 ext
  for ext in bed bim fam; do
    if [[ ! -s "${prefix}.${ext}" ]]; then
      echo "[MISS] $label missing: ${prefix}.${ext}"
      ok=0
    fi
  done
  [[ "$ok" == 1 ]] && echo "[OK]   $label prefix=$prefix (.bed/.bim/.fam found)"
  [[ "$ok" == 1 ]] && return 0 || return 1
}

lowpass_merge_status_code(){
  # 0 = directly runnable with current config; 1 = environment ok but needs project config; 2 = not runnable
  local env_ok=1 cfg_ok=1 sim_n="${LOWPASS_DOCTOR_SIM_N:-$(first_id_from_array "${PARALLEL_ARRAY:-1}")}" hp_prefix=""
  [[ -s "$LOWPASS_IBIS_FUNCTIONS" ]] || env_ok=0
  lowpass_functions_ok || env_ok=0
  path_ok "$PLINK2" exe || env_ok=0
  path_ok "$IBIS_BIN" exe || env_ok=0
  [[ -n "$(find_ibis_map)" ]] || env_ok=0
  [[ "$env_ok" == 1 ]] || { echo 2; return 0; }

  [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" ]] || cfg_ok=0
  if [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" ]]; then
    hp_prefix=$(expand_n_template "$HIGHPASS_PREFIX_TEMPLATE" "$sim_n")
    [[ -s "${hp_prefix}.bed" && -s "${hp_prefix}.bim" && -s "${hp_prefix}.fam" ]] || cfg_ok=0
  fi
  [[ -s "${GENOTYPE_FILE_LIST:-}" ]] || cfg_ok=0
  [[ -s "${SNP_KEEP_FILE_LIST:-}" ]] || cfg_ok=0
  [[ "$cfg_ok" == 1 ]] && echo 0 || echo 1
}

doctor_lowpass_merge(){
  echo ""
  echo "== lowpass-merge Comprehensive Check =="
  local ok=1 warn_only=0 sim_n="${LOWPASS_DOCTOR_SIM_N:-$(first_id_from_array "${PARALLEL_ARRAY:-1}")}"
  local hp_prefix map_file

  show_path_status "LOWPASS_IBIS_FUNCTIONS" "${LOWPASS_IBIS_FUNCTIONS:-}" file 1 || ok=0

  if [[ -s "${LOWPASS_IBIS_FUNCTIONS:-}" ]]; then
    func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" init_lowpass_collection && echo "[OK]   function init_lowpass_collection() found" || { echo "[MISS] function init_lowpass_collection() not found in $LOWPASS_IBIS_FUNCTIONS"; ok=0; }
    func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" process_all_units_for_sim && echo "[OK]   function process_all_units_for_sim() found" || { echo "[MISS] function process_all_units_for_sim() not found in $LOWPASS_IBIS_FUNCTIONS"; ok=0; }
    func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" collect_lowpass_units && echo "[OK]   function collect_lowpass_units() found" || { echo "[MISS] function collect_lowpass_units() not found in $LOWPASS_IBIS_FUNCTIONS"; ok=0; }
  fi

  show_path_status "PLINK2" "${PLINK2:-}" exe 1 || ok=0
  show_path_status "IBIS_BIN" "${IBIS_BIN:-}" exe 1 || ok=0
  show_path_status "IBIS_ADD_MAP" "${IBIS_ADD_MAP:-}" exe 0 || warn_only=1

  map_file="${MAP_FILE:-${IBIS_MAP_FILE:-}}"
  if [[ -n "$map_file" && -s "$map_file" ]]; then
    echo "[OK]   MAP_FILE/IBIS_MAP_FILE=$map_file"
  else
    map_file=$(find_ibis_map)
    if [[ -n "$map_file" ]]; then
      echo "[OK]   IBIS map candidate=$map_file"
    else
      echo "[MISS] MAP_FILE/IBIS_MAP_FILE missing; lowpass-merge IBIS step cannot add genetic map"
      ok=0
    fi
  fi

  echo "[INFO] lowpass doctor simulation id for template checks: $sim_n"
  if [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" ]]; then
    hp_prefix=$(expand_n_template "$HIGHPASS_PREFIX_TEMPLATE" "$sim_n")
    echo "[OK]   HIGHPASS_PREFIX_TEMPLATE=$HIGHPASS_PREFIX_TEMPLATE"
    check_plink_prefix "high-pass PLINK prefix for sim $sim_n" "$hp_prefix" 1 || ok=0
  else
    echo "[MISS] HIGHPASS_PREFIX_TEMPLATE not set"
    ok=0
  fi

  check_config_list_file "GENOTYPE_FILE_LIST" "${GENOTYPE_FILE_LIST:-}" 1 5 || ok=0
  check_config_list_file "SNP_KEEP_FILE_LIST" "${SNP_KEEP_FILE_LIST:-}" 1 5 || ok=0

  if [[ -n "${INCLUDE_FAM:-}" ]]; then show_path_status "INCLUDE_FAM" "$INCLUDE_FAM" file 1 || ok=0; else echo "[SKIP] INCLUDE_FAM not set"; fi
  if [[ -n "${OVERLAP_SNP:-}" ]]; then show_path_status "OVERLAP_SNP" "$OVERLAP_SNP" file 1 || ok=0; else echo "[SKIP] OVERLAP_SNP not set"; fi
  if [[ -n "${SIM_DIR:-}" ]]; then show_path_status "SIM_DIR" "$SIM_DIR" dir 0 || warn_only=1; else echo "[SKIP] SIM_DIR not set"; fi

  show_path_status "OUT_DIR" "$OUT_DIR" dir 1 || ok=0
  show_path_status "TMP_DIR" "$TMP_DIR" dir 1 || ok=0
  show_path_status "LOG_DIR" "$LOG_DIR" dir 1 || ok=0

  local code
  code=$(lowpass_merge_status_code)
  case "$code" in
    0) echo "[SUMMARY] lowpass-merge: READY（current config for sim $sim_n core checks passed）" ;;
    1) echo "[SUMMARY] lowpass-merge: Environment OK, project configuration/input incomplete" ;;
    2) echo "[SUMMARY] lowpass-merge: UNAVAILABLE，missing core functions or core tools/map" ;;
  esac

  [[ "$ok" == 1 ]] || return 1
  [[ "$warn_only" == 0 ]] || return 2
  return 0
}

capability_line(){
  local name="$1" status="$2" why="$3"
  printf '  %-24s %-12s %s\n' "$name" "$status" "$why"
}

doctor_resources(){
  echo ""
  echo "== Resource Check =="
  local ok=1 warn_only=0 f=""

  show_path_status "RESOURCE_DIR" "${RESOURCE_DIR:-}" dir 1 || ok=0

  f=$(find_pedsim_map)
  [[ -n "$f" ]] && echo "[OK]   PEDSIM_MAP candidate=$f" || { echo "[MISS] PEDSIM_MAP; checked config value and resources/maps/refined_mf_hg38_*.simmap"; ok=0; }

  f=$(find_pedsim_intf)
  [[ -n "$f" ]] && echo "[OK]   PEDSIM_INTF candidate=$f" || { echo "[MISS] PEDSIM_INTF; checked config value and resources/maps/sex_av_nu_p_hg38_campbell_*.tsv"; ok=0; }

  f=$(find_ibis_map)
  [[ -n "$f" ]] && echo "[OK]   IBIS_MAP_FILE candidate=$f" || { echo "[MISS] IBIS_MAP_FILE; checked config value, resources/genetic_map_GRCh38_merged.tab, resources/ibis/ibis.map, and resources/ibis.map"; ok=0; }

  local req_maps=0
  [[ "${REQUIRE_PHASE_MAPS:-0}" == 1 ]] && req_maps=1
  check_template_1_22 "${PHASE_MAP_TEMPLATE:-}" "PHASE_MAP_TEMPLATE" "$req_maps" || { [[ "$req_maps" == 1 ]] && ok=0 || warn_only=1; }

  if [[ "${PHASE_MAP_TEMPLATE:-}" != "$RESOURCE_PLINK_MAP_DIR/plink.chr{chr}.GRCh38.map" ]]; then
    check_template_1_22 "$RESOURCE_PLINK_MAP_DIR/plink.chr{chr}.GRCh38.map" "RESOURCE_PLINK_MAP_DIR default maps" 0 || warn_only=1
  fi

  f=$(find_snp_panel)
  [[ -n "$f" ]] && echo "[OK]   SNP panel candidate=$f" || { echo "[WARN] no SNP_PANEL_LIST set and no obvious SNP panel found"; warn_only=1; }

  if [[ "${REQUIRE_HAP_REF:-0}" == 1 ]]; then
    check_template_1_22 "${HAP_REF_TEMPLATE:-}" "HAP_REF_TEMPLATE" 1 || ok=0
    check_template_1_22 "${HAP_REF_TEMPLATE:-}.tbi" "HAP_REF_TEMPLATE index" 1 || ok=0
  else
    check_template_1_22 "${HAP_REF_TEMPLATE:-}" "HAP_REF_TEMPLATE" 0 || warn_only=1
  fi

  if [[ -d "$RESOURCE_AF_DIR" ]]; then
    f=$(find "$RESOURCE_AF_DIR" -maxdepth 1 -type f | head -n 1 || true)
    [[ -n "$f" ]] && echo "[OK]   allele_freq candidate=$f" || { echo "[WARN] allele_freq dir exists but is empty: $RESOURCE_AF_DIR"; warn_only=1; }
  else
    echo "[WARN] optional allele_freq dir not found: $RESOURCE_AF_DIR"; warn_only=1
  fi

  if [[ -d "$RESOURCE_REF_DIR" ]]; then
    f=$(find "$RESOURCE_REF_DIR" -maxdepth 1 -type f \( -name '*.fa' -o -name '*.fasta' \) | head -n 1 || true)
    [[ -n "$f" ]] && echo "[OK]   reference FASTA candidate=$f" || { echo "[WARN] reference dir exists but no FASTA found: $RESOURCE_REF_DIR"; warn_only=1; }
  else
    echo "[WARN] optional reference dir not found: $RESOURCE_REF_DIR"; warn_only=1
  fi

  [[ "$ok" == 1 ]] || return 1
  [[ "$warn_only" == 0 ]] || return 2
  return 0
}

doctor_capabilities(){
  echo ""
  echo "== Capability Matrix =="
  printf '  %-24s %-12s %s\n' "Feature" "Status" "Description"

  local core_scripts_ok=1 core_tools_ok=1
  path_ok "$SNPLIST_SCRIPT" file || core_scripts_ok=0
  path_ok "$PEDSIM_SCRIPT" file || core_scripts_ok=0
  path_ok "$LOWPASS_IBIS_FUNCTIONS" file || core_scripts_ok=0

  local bcftools_ok=0 plink2_ok=0 pedsim_ok=0 ibis_ok=0 addmap_ok=0 beagle_ok=0 sbatch_ok=0
  path_ok "$BCFTOOLS" exe && bcftools_ok=1
  path_ok "$PLINK2" exe && plink2_ok=1
  path_ok "$PEDSIM_BIN" exe && pedsim_ok=1
  path_ok "$IBIS_BIN" exe && ibis_ok=1
  path_ok "$IBIS_ADD_MAP" exe && addmap_ok=1
  path_ok "$BEAGLE_JAR" file && beagle_ok=1
  cmd_exists sbatch && sbatch_ok=1

  local pmap_ok=0 intf_ok=0 imap_ok=0 panel_ok=0 input_founder_ok=0 input_high_ok=0 snp_input_ok=0 phase_maps_ok=0 hap_ref_ok=0 lowpass_funcs_ok=0
  [[ -n "$(find_pedsim_map)" ]] && pmap_ok=1
  [[ -n "$(find_pedsim_intf)" ]] && intf_ok=1
  [[ -n "$(find_ibis_map)" ]] && imap_ok=1
  [[ -n "$(find_snp_panel)" ]] && panel_ok=1
  [[ -n "${FOUNDER_VCF:-}" && -s "${FOUNDER_VCF:-}" ]] && input_founder_ok=1
  [[ -n "${HIGH_PASS_VCF:-}" && -s "${HIGH_PASS_VCF:-}" ]] && input_high_ok=1
  [[ -n "${SNP_INPUT:-}" && -s "${SNP_INPUT:-}" ]] && snp_input_ok=1
  check_template_1_22 "${PHASE_MAP_TEMPLATE:-}" "_silent_phase_map_check" 1 >/dev/null 2>&1 && phase_maps_ok=1
  check_template_1_22 "${HAP_REF_TEMPLATE:-}" "_silent_hap_ref_check" 1 >/dev/null 2>&1 && hap_ref_ok=1
  func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" init_lowpass_collection && func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" process_all_units_for_sim && func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" collect_lowpass_units && lowpass_funcs_ok=1

  if [[ -s "$SNPLIST_SCRIPT" && "$bcftools_ok" == 1 ]]; then
    [[ "$snp_input_ok" == 1 || "$input_founder_ok" == 1 ]] && capability_line "snps" "READY" "Script and bcftools OK; SNP_INPUT/FOUNDER_VCF available" || capability_line "snps" "READY_WITH_INPUT" "Environment OK; requires --input at runtime or SNP_INPUT/FOUNDER_VCF in config"
  else
    capability_line "snps" "UNAVAILABLE" "Requires make_snp_keep_list.sh and bcftools"
  fi

  if [[ -s "$PEDSIM_SCRIPT" ]]; then
    capability_line "def" "READY" "Depends only on the Ped-Sim wrapper script; can generate .def and family plot"
  else
    capability_line "def" "UNAVAILABLE" "Missing PEDSIM_SCRIPT"
  fi

  if [[ -s "$PEDSIM_SCRIPT" && "$pedsim_ok" == 1 && "$pmap_ok" == 1 && "$intf_ok" == 1 ]]; then
    [[ "$input_founder_ok" == 1 ]] && capability_line "simulate/pedsim" "READY" "Ped-Sim, map/intf, and FOUNDER_VCF OK" || capability_line "simulate/pedsim" "READY_WITH_INPUT" "Environment OK; requires FOUNDER_VCF or runtime --vcf/--pedsim-vcf"
  else
    capability_line "simulate/pedsim" "UNAVAILABLE" "Requires PEDSIM_SCRIPT, ped-sim, PEDSIM_MAP, and PEDSIM_INTF"
  fi

  if [[ -s "$PEDSIM_SCRIPT" && "$plink2_ok" == 1 && "$beagle_ok" == 1 && "$phase_maps_ok" == 1 ]]; then
    [[ "$input_high_ok" == 1 && "$panel_ok" == 1 ]] && capability_line "phase" "READY" "plink2, beagle, map, HIGH_PASS_VCF, and SNP panel OK" || capability_line "phase" "READY_WITH_INPUT" "Environment OK; requires HIGH_PASS_VCF and SNP_PANEL_LIST/--panel"
  else
    capability_line "phase" "UNAVAILABLE" "Requires PEDSIM_SCRIPT, plink2, beagle.jar, and chr1-22 PLINK maps"
  fi

  if [[ -s "$LOWPASS_IBIS_FUNCTIONS" && "$plink2_ok" == 1 && "$ibis_ok" == 1 && "$imap_ok" == 1 ]]; then
    [[ "$addmap_ok" == 1 ]] && capability_line "kinship/ibis" "READY_WITH_INPUT" "IBIS Environment OK; requires --input at runtime; add-map available" || capability_line "kinship/ibis" "READY_WITH_INPUT" "IBIS Environment OK; requires --input at runtime; use --ibis-no-add-map if add-map is missing"
  else
    capability_line "kinship/ibis" "UNAVAILABLE" "Requires lowpass_ibis_functions.sh, plink2, ibis, and IBIS_MAP_FILE"
  fi

  case "$(lowpass_merge_status_code)" in
    0) capability_line "lowpass-merge" "READY" "Lowpass functions, IBIS/PLINK environment, high-pass prefix, and two list files passed checks" ;;
    1) capability_line "lowpass-merge" "CONFIG_REQUIRED" "Core functions and environment exist; requires complete HIGHPASS_PREFIX_TEMPLATE, GENOTYPE_FILE_LIST, SNP_KEEP_FILE_LIST, and project inputs" ;;
    2) capability_line "lowpass-merge" "UNAVAILABLE" "Missing init/process/collect functions in LOWPASS_IBIS_FUNCTIONS, or missing plink2/ibis/IBIS map" ;;
  esac

  if [[ -s "$SNPLIST_SCRIPT" && -s "$PEDSIM_SCRIPT" && -s "$LOWPASS_IBIS_FUNCTIONS" && "$bcftools_ok" == 1 && "$pedsim_ok" == 1 && "$ibis_ok" == 1 && "$plink2_ok" == 1 && "$pmap_ok" == 1 && "$intf_ok" == 1 && "$imap_ok" == 1 ]]; then
    capability_line "workflow simulate-kinship" "READY_WITH_INPUT" "Environment complete; project-specific founder/highpass/SNP/output settings required"
  else
    capability_line "workflow simulate-kinship" "UNAVAILABLE" "Requires snps, simulate, and kinship environments to be available"
  fi

  capability_line "parallel local" "STATUS_UNKNOWN" "Status message translated to English"
  [[ "$sbatch_ok" == 1 ]] && capability_line "parallel slurm" "STATUS_UNKNOWN" "Status message translated to English"

  if [[ "$hap_ref_ok" == 1 ]]; then
    capability_line "haplotype reference" "STATUS_UNKNOWN" "Status message translated to English"
  else
    capability_line "haplotype reference" "NOT_CONFIGURED" "Required only for extended workflows that need Beagle/GLIMPSE references"
  fi
}

doctor_project_inputs(){
  echo ""
  echo "== Project Input Check =="
  local ok=1
  for f in PROJECT_DIR OUT_DIR TMP_DIR LOG_DIR FOUNDER_VCF HIGH_PASS_VCF SNP_PANEL_LIST SNP_INPUT; do
    local v="${!f:-}"
    case "$f" in
      PROJECT_DIR|OUT_DIR|TMP_DIR|LOG_DIR)
        show_path_status "$f" "$v" dir 0 || true
        ;;
      SNP_INPUT)
        [[ -z "$v" ]] && { echo "[SKIP] SNP_INPUT not set; will fall back to FOUNDER_VCF when available"; continue; }
        show_path_status "$f" "$v" file 0 || true
        ;;
      *)
        [[ -z "$v" ]] && { echo "[SKIP] $f not set"; continue; }
        show_path_status "$f" "$v" file 1 || ok=0
        ;;
    esac
  done
  [[ "$ok" == 1 ]] && return 0 || return 1
}

# ---------- doctor config check ----------
doctor_config_usage(){
  cat >&2 <<'USAGE'
Usage:
  bash main.sh --config CONFIG doctor config <module|all>

Modules:
  snps
  phase
  def
  simulate
  kinship
  lowpass-merge
  evaluate
  workflow
  all

Examples:
  bash main.sh --config configs/kinship.ibis.txt doctor config kinship
  bash main.sh --config configs/phase.beagle.txt doctor config phase
  bash main.sh --config configs/snps.GP099_BF50.txt doctor config snps
USAGE
}

doctor_config_input_any(){
  local label="$1" value="${2:-}" required="${3:-1}" hint="${4:-}"
  if [[ -z "$value" ]]; then
    if [[ "$required" == 1 ]]; then
      echo "[MISS] $label=<not set>${hint:+  # $hint}"
      return 1
    fi
    echo "[SKIP] $label not set${hint:+  # $hint}"
    return 0
  fi

  if [[ -s "$value" || -d "$value" ]]; then
    echo "[OK]   $label=$value"
    return 0
  fi

  if [[ -s "${value}.bed" && -s "${value}.bim" && -s "${value}.fam" ]]; then
    echo "[OK]   $label=$value (.bed/.bim/.fam prefix found)"
    return 0
  fi

  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label not found as file/dir or PLINK prefix: $value${hint:+  # $hint}"
    return 1
  fi

  echo "[WARN] $label not found: $value${hint:+  # $hint}"
  return 0
}

doctor_check_value(){
  local label="$1" value="${2:-}" required="${3:-1}" hint="${4:-}"
  if [[ -n "$value" ]]; then
    echo "[OK]   $label=$value${hint:+  # $hint}"
    return 0
  fi
  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label=<not set>${hint:+  # $hint}"
    return 1
  fi
  echo "[SKIP] $label not set${hint:+  # $hint}"
  return 0
}

doctor_check_template_for_chrs(){
  local label="$1" template="${2:-}" chr_spec="${3:-1}" required="${4:-1}" hint="${5:-}"
  local ok=1 missing=() chr f
  if [[ -z "$template" ]]; then
    if [[ "$required" == 1 ]]; then
      echo "[MISS] $label template is empty${hint:+  # $hint}"
      return 1
    fi
    echo "[SKIP] $label not set${hint:+  # $hint}"
    return 0
  fi

  while IFS= read -r chr; do
    [[ -n "$chr" ]] || continue
    f="${template//\{chr\}/$chr}"
    if [[ ! -s "$f" ]]; then
      missing+=("$chr")
      ok=0
    fi
  done < <(echo "$chr_spec" | tr ',' '\n' | awk '
    function stripchr(x){sub(/^chr/,"",x); sub(/^CHR/,"",x); return x}
    NF==0{next}
    {
      x=$1
      if (x ~ /-/) {
        split(x,a,"-"); s=stripchr(a[1]); e=stripchr(a[2])
        if (s ~ /^[0-9]+$/ && e ~ /^[0-9]+$/ && s <= e) {
          for(i=s;i<=e;i++) print i
        } else print stripchr(x)
      } else print stripchr(x)
    }')

  if [[ "$ok" == 1 ]]; then
    echo "[OK]   $label=$template"
    return 0
  fi

  if [[ "$required" == 1 ]]; then
    echo "[MISS] $label missing chromosomes: ${missing[*]} template=$template"
    return 1
  fi

  echo "[WARN] $label incomplete; missing chromosomes: ${missing[*]} template=$template"
  return 0
}

doctor_config_snps(){
  echo ""
  echo "== Config Check: snps =="
  local ok=1
  show_path_status "SNPLIST_SCRIPT" "${SNPLIST_SCRIPT:-}" file 1 || ok=0
  show_path_status "BCFTOOLS" "${BCFTOOLS:-}" exe 1 || ok=0

  if [[ -n "${SNP_INPUT:-}" ]]; then
    show_path_status "SNP_INPUT" "$SNP_INPUT" file 1 || ok=0
  elif [[ -n "${SNP_INPUT_LIST:-}" ]]; then
    show_path_status "SNP_INPUT_LIST" "$SNP_INPUT_LIST" file 1 || ok=0
  else
    echo "[MISS] SNP_INPUT or SNP_INPUT_LIST not set"
    ok=0
  fi

  [[ -n "${SNP_PANEL_LIST:-}" ]] && show_path_status "SNP_PANEL_LIST" "$SNP_PANEL_LIST" file 0 || echo "[SKIP] SNP_PANEL_LIST not set"
  doctor_check_value "SNP_GP" "${SNP_GP:-}" 1 "GP threshold" || ok=0
  doctor_check_value "SNP_BF" "${SNP_BF:-}" 1 "BF threshold" || ok=0
  doctor_check_value "SNP_ID_STYLE" "${SNP_ID_STYLE:-}" 1 "chr/nochr/vcf" || ok=0
  doctor_check_value "SNP_SAMPLE_MODE" "${SNP_SAMPLE_MODE:-}" 1 "any/all/first" || ok=0
  doctor_check_value "SNP_OUT" "${SNP_OUT:-}" 1 "output SNP keep list" || ok=0

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} snps"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] snps config: READY"; return 0; } || { echo "[SUMMARY] snps config: NEEDS_EDIT"; return 1; }
}

doctor_config_phase(){
  echo ""
  echo "== Config Check: phase =="
  local ok=1
  show_path_status "PEDSIM_SCRIPT" "${PEDSIM_SCRIPT:-}" file 1 || ok=0
  show_path_status "PLINK2" "${PLINK2:-}" exe 1 || ok=0
  show_path_status "BEAGLE_JAR" "${BEAGLE_JAR:-}" file 1 || ok=0
  show_path_status "HIGH_PASS_VCF" "${HIGH_PASS_VCF:-}" file 1 || ok=0
  [[ -n "${SNP_PANEL_LIST:-}" ]] && show_path_status "SNP_PANEL_LIST" "$SNP_PANEL_LIST" file 0 || echo "[SKIP] SNP_PANEL_LIST not set"
  doctor_check_value "PHASE_CHR" "${PHASE_CHR:-}" 1 "chromosome or range" || ok=0
  doctor_check_value "PHASE_XMX" "${PHASE_XMX:-}" 0 "Beagle Java memory" || true
  doctor_check_template_for_chrs "PHASE_REF_TEMPLATE" "${PHASE_REF_TEMPLATE:-}" "${PHASE_CHR:-1}" 1 "Beagle reference panel" || ok=0
  doctor_check_template_for_chrs "PHASE_MAP_TEMPLATE" "${PHASE_MAP_TEMPLATE:-}" "${PHASE_CHR:-1}" 1 "Beagle genetic map" || ok=0

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} phase"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] phase config: READY"; return 0; } || { echo "[SUMMARY] phase config: NEEDS_EDIT"; return 1; }
}

doctor_config_def(){
  echo ""
  echo "== Config Check: def =="
  local ok=1
  show_path_status "PEDSIM_SCRIPT" "${PEDSIM_SCRIPT:-}" file 1 || ok=0
  doctor_check_value "SIM_RELATIONSHIP" "${SIM_RELATIONSHIP:-}" 1 || ok=0
  doctor_check_value "SIM_DEGREE" "${SIM_DEGREE:-}" 1 || ok=0
  doctor_check_value "SIM_HALF" "${SIM_HALF:-}" 1 || ok=0
  doctor_check_value "SIM_COPIES" "${SIM_COPIES:-}" 1 || ok=0
  doctor_check_value "SIM_DEF_NAME" "${SIM_DEF_NAME:-}" 1 || ok=0
  [[ -n "${FOUNDER_VCF:-}" ]] && show_path_status "FOUNDER_VCF" "$FOUNDER_VCF" file 0 || echo "[SKIP] FOUNDER_VCF not set; def-only may still run if n-founders is provided internally"

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} def"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] def config: READY"; return 0; } || { echo "[SUMMARY] def config: NEEDS_EDIT"; return 1; }
}

doctor_config_simulate(){
  echo ""
  echo "== Config Check: simulate =="
  local ok=1
  show_path_status "PEDSIM_SCRIPT" "${PEDSIM_SCRIPT:-}" file 1 || ok=0
  show_path_status "PEDSIM_BIN" "${PEDSIM_BIN:-}" exe 1 || ok=0
  show_path_status "PEDSIM_MAP" "${PEDSIM_MAP:-}" file 1 || ok=0
  if [[ -n "${PEDSIM_INTF:-}" ]]; then
    show_path_status "PEDSIM_INTF" "$PEDSIM_INTF" file 1 || ok=0
  elif [[ -n "${PEDSIM_FIXED_CO:-}" ]]; then
    show_path_status "PEDSIM_FIXED_CO" "$PEDSIM_FIXED_CO" file 1 || ok=0
  else
    echo "[MISS] PEDSIM_INTF or PEDSIM_FIXED_CO not set"
    ok=0
  fi
  show_path_status "FOUNDER_VCF" "${FOUNDER_VCF:-}" file 1 || ok=0
  doctor_check_value "SIM_RELATIONSHIP" "${SIM_RELATIONSHIP:-}" 1 || ok=0
  doctor_check_value "SIM_DEGREE" "${SIM_DEGREE:-}" 1 || ok=0
  doctor_check_value "SIM_COPIES" "${SIM_COPIES:-}" 1 || ok=0
  doctor_check_value "SIM_DEF_NAME" "${SIM_DEF_NAME:-}" 1 || ok=0

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} simulate"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] simulate config: READY"; return 0; } || { echo "[SUMMARY] simulate config: NEEDS_EDIT"; return 1; }
}

doctor_config_kinship(){
  echo ""
  echo "== Config Check: kinship =="
  local ok=1
  show_path_status "LOWPASS_IBIS_FUNCTIONS" "${LOWPASS_IBIS_FUNCTIONS:-}" file 1 || ok=0
  if [[ -s "${LOWPASS_IBIS_FUNCTIONS:-}" ]]; then
    func_exists_in_file "$LOWPASS_IBIS_FUNCTIONS" run_ibis_only_workflow && echo "[OK]   function run_ibis_only_workflow() found" || { echo "[MISS] function run_ibis_only_workflow() not found in $LOWPASS_IBIS_FUNCTIONS"; ok=0; }
  fi
  show_path_status "PLINK2" "${PLINK2:-}" exe 1 || ok=0
  show_path_status "IBIS_BIN" "${IBIS_BIN:-}" exe 1 || ok=0
  doctor_config_input_any "IBIS_INPUT" "${IBIS_INPUT:-}" 1 "VCF/BCF file, directory, or PLINK prefix" || ok=0

  if [[ "${IBIS_ADD_MAP_ENABLED:-1}" == 1 ]]; then
    show_path_status "IBIS_ADD_MAP" "${IBIS_ADD_MAP:-}" exe 0 || true
    show_path_status "IBIS_MAP_FILE" "${IBIS_MAP_FILE:-${MAP_FILE:-}}" file 1 || ok=0
  else
    echo "[SKIP] IBIS_MAP_FILE because IBIS_ADD_MAP_ENABLED=0"
  fi

  [[ -n "${IBIS_EXTRACT:-}" ]] && show_path_status "IBIS_EXTRACT" "$IBIS_EXTRACT" file 0 || echo "[SKIP] IBIS_EXTRACT not set"
  doctor_check_value "IBIS_OUT_PREFIX" "${IBIS_OUT_PREFIX:-$OUT_DIR/kinship/ibisOut}" 1 "output prefix" || ok=0
  doctor_check_value "IBIS_MIN_L" "${IBIS_MIN_L:-}" 1 || ok=0
  doctor_check_value "IBIS_MT" "${IBIS_MT:-}" 1 || ok=0
  doctor_check_value "IBIS_ER" "${IBIS_ER:-}" 1 || ok=0
  doctor_check_value "IBIS_THREADS" "${IBIS_THREADS:-}" 1 || ok=0

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} kinship"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] kinship config: READY"; return 0; } || { echo "[SUMMARY] kinship config: NEEDS_EDIT"; return 1; }
}

doctor_config_lowpass_merge(){
  echo ""
  echo "== Config Check: lowpass-merge =="
  local ok=1 sim_n="${LOWPASS_DOCTOR_SIM_N:-$(first_id_from_array "${PARALLEL_ARRAY:-1}")}" hp_prefix=""
  show_path_status "LOWPASS_IBIS_FUNCTIONS" "${LOWPASS_IBIS_FUNCTIONS:-}" file 1 || ok=0
  if [[ -s "${LOWPASS_IBIS_FUNCTIONS:-}" ]]; then
    lowpass_functions_ok && echo "[OK]   lowpass merge functions found" || { echo "[MISS] required lowpass merge functions not found in $LOWPASS_IBIS_FUNCTIONS"; ok=0; }
  fi
  show_path_status "PLINK" "${PLINK:-}" exe 1 || ok=0
  show_path_status "PLINK2" "${PLINK2:-}" exe 1 || ok=0
  show_path_status "IBIS_BIN" "${IBIS_BIN:-}" exe 1 || ok=0
  show_path_status "IBIS_MAP_FILE" "${IBIS_MAP_FILE:-${MAP_FILE:-}}" file 1 || ok=0
  doctor_check_value "HIGHPASS_PREFIX_TEMPLATE" "${HIGHPASS_PREFIX_TEMPLATE:-}" 1 "template with {n}" || ok=0
  if [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" ]]; then
    hp_prefix=$(expand_n_template "$HIGHPASS_PREFIX_TEMPLATE" "$sim_n")
    check_plink_prefix "high-pass prefix for sim $sim_n" "$hp_prefix" 1 || ok=0
  fi
  check_config_list_file "GENOTYPE_FILE_LIST" "${GENOTYPE_FILE_LIST:-}" 1 5 || ok=0
  if [[ -n "${SNP_KEEP_FILE_LIST:-}" ]]; then
    check_config_list_file "SNP_KEEP_FILE_LIST" "$SNP_KEEP_FILE_LIST" 1 5 || ok=0
  else
    show_path_status "OVERLAP_SNP" "${OVERLAP_SNP:-}" file 1 || ok=0
  fi

  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} lowpass-merge $sim_n"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] lowpass-merge config: READY"; return 0; } || { echo "[SUMMARY] lowpass-merge config: NEEDS_EDIT"; return 1; }
}


doctor_config_evaluate(){
  echo ""
  echo "== Config Check: evaluate =="
  local ok=1
  doctor_check_value "EVAL_TRUTH_TYPE" "${EVAL_TRUTH_TYPE:-auto}" 0 "auto/kinship/lowpass-merge/raw-seg/coef/segcoef" || true
  doctor_config_input_any "EVAL_TRUTH" "${EVAL_TRUTH:-}" 1 "truth file, directory, or output prefix" || ok=0
  doctor_check_value "EVAL_PRED_TYPE" "${EVAL_PRED_TYPE:-auto}" 0 "auto/kinship/lowpass-merge/raw-seg/coef/segcoef" || true
  doctor_config_input_any "EVAL_PRED" "${EVAL_PRED:-}" 1 "prediction file, directory, or output prefix" || ok=0
  doctor_check_value "EVAL_OUT_PREFIX" "${EVAL_OUT_PREFIX:-$OUT_DIR/evaluate/run1}" 1 "output prefix" || ok=0
  doctor_check_value "EVAL_REL_CUTOFF_CM" "${EVAL_REL_CUTOFF_CM:-0}" 0 "related if total_cM > cutoff" || true
  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} evaluate"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] evaluate config: READY"; return 0; } || { echo "[SUMMARY] evaluate config: NEEDS_EDIT"; return 1; }
}

doctor_config_workflow(){
  echo ""
  echo "== Config Check: workflow ${WORKFLOW_NAME:-simulate-kinship} =="
  local ok=1
  case "${WORKFLOW_NAME:-simulate-kinship}" in
    simulate-kinship)
      doctor_config_snps || ok=0
      doctor_config_simulate || ok=0
      doctor_config_kinship || ok=0
      ;;
    *)
      echo "[MISS] unsupported WORKFLOW_NAME=${WORKFLOW_NAME:-}"
      ok=0
      ;;
  esac
  echo "[COMMAND] bash main.sh --config ${CONFIG_FILE:-config.txt} workflow ${WORKFLOW_NAME:-simulate-kinship}"
  [[ "$ok" == 1 ]] && { echo "[SUMMARY] workflow config: READY"; return 0; } || { echo "[SUMMARY] workflow config: NEEDS_EDIT"; return 1; }
}

doctor_config_infer_module(){
  # Infer the most likely module from the loaded runtime variables.
  # This is only used when user runs: bash main.sh --config xxx doctor
  # Explicit forms such as doctor config kinship still override this.
  if [[ -n "${IBIS_INPUT:-}" ]]; then echo "kinship"; return 0; fi
  if [[ -n "${EVAL_TRUTH:-}" || -n "${EVAL_PRED:-}" ]]; then echo "evaluate"; return 0; fi
  if [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" || -n "${GENOTYPE_FILE_LIST:-}" ]]; then echo "lowpass-merge"; return 0; fi
  if [[ -n "${PHASE_REF_TEMPLATE:-}" || -n "${HIGH_PASS_VCF:-}" ]]; then echo "phase"; return 0; fi
  if [[ -n "${SNP_INPUT:-}" || -n "${SNP_INPUT_LIST:-}" ]]; then echo "snps"; return 0; fi
  if [[ -n "${FOUNDER_VCF:-}" && -n "${PEDSIM_BIN:-}" && -n "${PEDSIM_MAP:-}" ]]; then echo "simulate"; return 0; fi
  if [[ -n "${SIM_RELATIONSHIP:-}" || -n "${SIM_DEF_NAME:-}" ]]; then echo "def"; return 0; fi
  echo "all"
}

doctor_config(){
  local module="${1:-auto}"
  [[ "$module" == "--module" ]] && module="${2:-auto}"
  [[ "$module" == "-h" || "$module" == "--help" ]] && { doctor_config_usage; return 0; }

  echo "== Loaded Config Runtime Check =="
  echo "[INFO] PROJECT_DIR=$PROJECT_DIR"
  echo "[INFO] OUT_DIR=$OUT_DIR"
  echo "[INFO] TMP_DIR=$TMP_DIR"
  echo "[INFO] LOG_DIR=$LOG_DIR"

  local ok=1
  case "$module" in
    auto)
      module="$(doctor_config_infer_module)"
      echo "[INFO] inferred module=$module"
      case "$module" in
        snps|snplist|snp-list) doctor_config_snps || ok=0 ;;
        phase) doctor_config_phase || ok=0 ;;
        def|make-def) doctor_config_def || ok=0 ;;
        simulate|pedsim) doctor_config_simulate || ok=0 ;;
        kinship|ibis|ibis-only) doctor_config_kinship || ok=0 ;;
        lowpass-merge|merge-lowpass) doctor_config_lowpass_merge || ok=0 ;;
        evaluate|eval) doctor_config_evaluate || ok=0 ;;
        all)
          doctor_config_snps || ok=0
          doctor_config_phase || ok=0
          doctor_config_def || ok=0
          doctor_config_simulate || ok=0
          doctor_config_kinship || ok=0
          ;;
      esac
      ;;
    all)
      doctor_config_snps || ok=0
      doctor_config_phase || ok=0
      doctor_config_def || ok=0
      doctor_config_simulate || ok=0
      doctor_config_kinship || ok=0
      doctor_config_lowpass_merge || ok=0
      doctor_config_evaluate || ok=0
      ;;
    snps|snplist|snp-list) doctor_config_snps || ok=0 ;;
    phase) doctor_config_phase || ok=0 ;;
    def|make-def) doctor_config_def || ok=0 ;;
    simulate|pedsim) doctor_config_simulate || ok=0 ;;
    kinship|ibis|ibis-only) doctor_config_kinship || ok=0 ;;
    lowpass-merge|merge-lowpass) doctor_config_lowpass_merge || ok=0 ;;
    evaluate|eval) doctor_config_evaluate || ok=0 ;;
    workflow) doctor_config_workflow || ok=0 ;;
    *) die "unknown doctor config module: $module; use snps, phase, def, simulate, kinship, lowpass-merge, evaluate, workflow, or all" ;;
  esac

  echo ""
  if [[ "$ok" == 1 ]]; then
    echo "doctor config summary: READY"
  else
    echo "doctor config summary: NEEDS_EDIT"
    exit 1
  fi
}

doctor(){
  local mode="${1:-all}"
  echo "mix_detect doctor (main.sh $VERSION)"
  echo "CONFIG_FILE=${CONFIG_FILE:-<none; using built-in auto defaults>}"

  # Backward-compatible behavior:
  #   bash main.sh doctor                    -> full environment/resources check
  #   bash main.sh --config xxx doctor       -> runtime check for the loaded config
  #   bash main.sh --config xxx doctor all   -> force full environment/resources check
  #   bash main.sh --config xxx doctor config kinship -> explicit module config check
  if [[ "$mode" == "all" && -n "${CONFIG_FILE:-}" && $# -eq 0 ]]; then
    doctor_config auto
    return
  fi

  local ok=1

  case "$mode" in
    config|check-config|validate-config)
      shift || true
      doctor_config "$@"
      return
      ;;
    all|env|environment|basic|resources|resource|project|capabilities|matrix|lowpass|lowpass-merge) ;;
    *) die "unknown doctor mode: $mode; use all, env, resources, project, capabilities, lowpass, or config" ;;
  esac

  if [[ "$mode" == "all" || "$mode" == "env" || "$mode" == "environment" || "$mode" == "basic" ]]; then
    echo ""
    echo "== Environment / Tool Check =="
    show_path_status "TOOL_ROOT" "$TOOL_ROOT" dir 1 || ok=0
    show_path_status "BIN_DIR" "$BIN_DIR" dir 0 || true
    show_path_status "SNPLIST_SCRIPT" "$SNPLIST_SCRIPT" file 1 || ok=0
    show_path_status "PEDSIM_SCRIPT" "$PEDSIM_SCRIPT" file 1 || ok=0
    show_path_status "LOWPASS_IBIS_FUNCTIONS" "$LOWPASS_IBIS_FUNCTIONS" file 1 || ok=0
    show_path_status "BCFTOOLS" "$BCFTOOLS" exe 1 || ok=0
    show_path_status "PLINK" "$PLINK" exe 0 || true
    show_path_status "PLINK2" "$PLINK2" exe 1 || ok=0
    show_path_status "PEDSIM_BIN" "$PEDSIM_BIN" exe 1 || ok=0
    show_path_status "IBIS_BIN" "$IBIS_BIN" exe 1 || ok=0
    show_path_status "IBIS_ADD_MAP" "$IBIS_ADD_MAP" exe 0 || true
    show_path_status "BEAGLE_JAR" "$BEAGLE_JAR" file 0 || true
    cmd_exists awk && echo "[OK]   awk=$(command -v awk)" || { echo "[MISS] awk"; ok=0; }
    cmd_exists sort && echo "[OK]   sort=$(command -v sort)" || { echo "[MISS] sort"; ok=0; }
    cmd_exists rsync && echo "[OK]   rsync=$(command -v rsync)" || echo "[WARN] rsync not found; staging can still use cp fallback only if implemented by site wrapper"
    cmd_exists sbatch && echo "[OK]   sbatch=$(command -v sbatch)" || echo "[WARN] sbatch not found; Slurm parallel unavailable on this machine"
  fi

  if [[ "$mode" == "all" || "$mode" == "resources" || "$mode" == "resource" ]]; then
    doctor_resources || ok=0
  fi

  if [[ "$mode" == "all" || "$mode" == "project" ]]; then
    doctor_project_inputs || ok=0
  fi

  if [[ "$mode" == "all" || "$mode" == "lowpass" || "$mode" == "lowpass-merge" ]]; then
    doctor_lowpass_merge || ok=0
  fi

  if [[ "$mode" == "all" || "$mode" == "capabilities" || "$mode" == "matrix" ]]; then
    doctor_capabilities
  fi

  echo ""
  if [[ "$ok" == 1 ]]; then
    echo "doctor summary: PASS"
  else
    echo "doctor summary: FAIL/WARN - see missing items above"
    exit 1
  fi
}

# ---------- staging ----------
resolve_scratch_root(){
  [[ -n "$LOCAL_SCRATCH_OVERRIDE" ]] && { echo "$LOCAL_SCRATCH_OVERRIDE"; return; }
  [[ "${LOCAL_SCRATCH_ROOT:-auto}" != "auto" ]] && { echo "$LOCAL_SCRATCH_ROOT"; return; }
  [[ -n "${SLURM_TMPDIR:-}" ]] && { echo "$SLURM_TMPDIR"; return; }
  [[ -n "${TMPDIR:-}" ]] && { echo "$TMPDIR"; return; }
  [[ -d "/scratch/${USER:-}" ]] && { echo "/scratch/${USER}"; return; }
  echo "/tmp"
}
should_stage(){
  [[ "$FORCE_STAGE" == 1 ]] && return 0
  [[ "$FORCE_STAGE" == 0 ]] && return 1
  [[ "${STAGE_TO_LOCAL:-auto}" == 1 || "${STAGE_TO_LOCAL:-auto}" == "yes" ]] && return 0
  [[ "${STAGE_TO_LOCAL:-auto}" == 0 || "${STAGE_TO_LOCAL:-auto}" == "no" ]] && return 1
  [[ -n "${SLURM_JOB_ID:-}" ]] && return 0
  return 1
}
stage_file(){ local f="$1" dir="$2"; [[ -s "$f" ]] || { echo "$f"; return; }; local b="$(basename "$f")"; cp -f "$f" "$dir/$b"; echo "$dir/$b"; }
run_with_status(){
  local workflow="$1" task_id="$2"; shift 2
  local status_dir="$LOG_DIR/status"; mkdir -p "$status_dir"
  rm -f "$status_dir/${workflow}.${task_id}.done" "$status_dir/${workflow}.${task_id}.failed"
  if "$@"; then date > "$status_dir/${workflow}.${task_id}.done"; else date > "$status_dir/${workflow}.${task_id}.failed"; return 1; fi
}


setup_staging(){
  local cmd="$1"
  case "$cmd" in doctor|profile|config|init|help|-h|--help) return 0;; esac
  should_stage || return 0
  local root stage_id in_dir out_dir tmp_dir
  root="$(resolve_scratch_root)"
  stage_id="mixdetect_${cmd}_${SLURM_JOB_ID:-local}_${SLURM_ARRAY_TASK_ID:-${TASK_ID:-$$}}"
  STAGE_DIR="$root/$stage_id"
  STAGE_SHARED_OUT_DIR="$OUT_DIR"
  STAGE_SHARED_TMP_DIR="$TMP_DIR"
  mkdir -p "$STAGE_DIR/input" "$STAGE_DIR/results" "$STAGE_DIR/tmp"
  info "staging enabled: $STAGE_DIR"
  if [[ "${STAGE_RANDOM_SLEEP:-0}" == 1 && -n "${SLURM_JOB_ID:-}" ]]; then
    local max="${STAGE_RANDOM_SLEEP_MAX:-120}"; sleep $(( RANDOM % (max + 1) ))
  fi
  local v f staged
  for v in FOUNDER_VCF HIGH_PASS_VCF SNP_INPUT SNP_PANEL_LIST PEDSIM_MAP PEDSIM_INTF IBIS_MAP_FILE IBIS_INPUT IBIS_EXTRACT; do
    f="${!v:-}"
    if [[ -n "$f" && -s "$f" ]]; then
      staged="$(stage_file "$f" "$STAGE_DIR/input")"
      printf -v "$v" '%s' "$staged"; export "$v"
    fi
  done
  TMP_DIR="$STAGE_DIR/tmp"; export TMP_DIR
  if [[ "${STAGE_OUTPUTS_LOCAL:-1}" == 1 ]]; then
    OUT_DIR="$STAGE_DIR/results"; export OUT_DIR
  fi
  cleanup_staging(){
    local ec="$?"
    if [[ "$ec" == 0 && "${COPY_RESULTS_BACK:-1}" == 1 && -d "${STAGE_SHARED_OUT_DIR:-}" && "${OUT_DIR:-}" == "$STAGE_DIR/results" ]]; then
      mkdir -p "$STAGE_SHARED_OUT_DIR"
      cp -a "$OUT_DIR"/. "$STAGE_SHARED_OUT_DIR"/ 2>/dev/null || true
    fi
    if [[ "$ec" == 0 && "${CLEAN_LOCAL_SCRATCH:-1}" == 1 ]]; then
      rm -rf "$STAGE_DIR"
    elif [[ "$ec" != 0 && "${KEEP_LOCAL_ON_FAIL:-1}" == 1 ]]; then
      warn "task failed; keeping local scratch: $STAGE_DIR"
    fi
    exit "$ec"
  }
  trap cleanup_staging EXIT
}

# ---------- module runners ----------
run_snps(){
  fast_preflight snps
  local args=()
  [[ -n "${SNP_INPUT:-}" ]] && args+=(--input "$SNP_INPUT")
  [[ -n "${SNP_INPUT_LIST:-}" ]] && args+=(--input-list "$SNP_INPUT_LIST")
  [[ -n "${SNP_PANEL_LIST:-}" ]] && args+=(--merge-list "$SNP_PANEL_LIST")
  args+=(--gp "$SNP_GP" --bf "$SNP_BF" --id-style "$SNP_ID_STYLE" --sample-mode "$SNP_SAMPLE_MODE" --out "$SNP_OUT" --bcftools "$BCFTOOLS" --threads "$THREADS")
  [[ -n "${SNP_REGION:-}" ]] && args+=(--region "$SNP_REGION")
  [[ -n "${SNP_MERGE_MODE:-}" ]] && args+=(--merge-mode "$SNP_MERGE_MODE")
  args+=("$@")
  info "running snps"
  bash "$SNPLIST_SCRIPT" "${args[@]}"
}

translate_pedsim_args(){
  local -n out=$1; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rel) out+=(--relationship "$2"); shift 2 ;;
      --vcf) out+=(--pedsim-vcf "$2"); shift 2 ;;
      --chr) out+=(--phase-chr "$2"); shift 2 ;;
      --panel) out+=(--phase-marker-list "$2"); shift 2 ;;
      --input-vcf) out+=(--phase-input-vcf "$2"); shift 2 ;;
      *) out+=("$1"); shift ;;
    esac
  done
}

base_pedsim_args(){
  local -n a=$1
  a+=(--out-dir "$OUT_DIR")
  [[ -n "${SIM_RELATIONSHIP:-}" ]] && a+=(--relationship "$SIM_RELATIONSHIP")
  [[ -n "${SIM_DEGREE:-}" ]] && a+=(--degree "$SIM_DEGREE")
  [[ -n "${SIM_HALF:-}" ]] && a+=(--half "$SIM_HALF")
  [[ -n "${SIM_COPIES:-}" ]] && a+=(--copies "$SIM_COPIES")
  [[ -n "${SIM_DEF_NAME:-}" ]] && a+=(--def-name "$SIM_DEF_NAME")
  [[ -n "${SIM_PARENT_SEX:-}" ]] && a+=(--parent-sex "$SIM_PARENT_SEX")
  [[ -n "${SIM_PRINT_SPEC:-}" ]] && a+=(--print-spec "$SIM_PRINT_SPEC")
  [[ -n "${FOUNDER_VCF:-}" ]] && a+=(--pedsim-vcf "$FOUNDER_VCF")
  [[ -n "${SIM_SEED:-}" ]] && a+=(--founder-random-seed "$SIM_SEED")
}

run_phase(){
  fast_preflight phase
  local args=(--phase-only --out-dir "$OUT_DIR" --phase-plink2 "$PLINK2")
  [[ -n "${HIGH_PASS_VCF:-}" ]] && args+=(--phase-input-vcf "$HIGH_PASS_VCF")
  [[ -n "${SNP_PANEL_LIST:-}" ]] && args+=(--phase-marker-list "$SNP_PANEL_LIST")
  [[ -n "${PHASE_CHR:-}" ]] && args+=(--phase-chr "$PHASE_CHR")
  [[ -n "${BEAGLE_JAR:-}" ]] && args+=(--phase-beagle-jar "$BEAGLE_JAR")
  [[ -n "${PHASE_REF_TEMPLATE:-}" ]] && args+=(--phase-ref-template "$PHASE_REF_TEMPLATE")
  [[ -n "${PHASE_MAP_TEMPLATE:-}" ]] && args+=(--phase-map-template "$PHASE_MAP_TEMPLATE")
  [[ -n "${PHASE_XMX:-}" ]] && args+=(--phase-xmx "$PHASE_XMX")
  translate_pedsim_args args "$@"
  bash "$PEDSIM_SCRIPT" "${args[@]}"
}
run_def(){
  fast_preflight def
  local args=(); base_pedsim_args args; translate_pedsim_args args "$@"; bash "$PEDSIM_SCRIPT" "${args[@]}"
}
run_simulate(){
  fast_preflight simulate
  local args=(--run-pedsim); base_pedsim_args args
  [[ -n "${PEDSIM_BIN:-}" ]] && args+=(--pedsim-bin "$PEDSIM_BIN")
  [[ -n "${PEDSIM_MAP:-}" ]] && args+=(--pedsim-map "$PEDSIM_MAP")
  [[ -n "${PEDSIM_INTF:-}" ]] && args+=(--pedsim-intf "$PEDSIM_INTF")
  [[ -n "${PEDSIM_FIXED_CO:-}" ]] && args+=(--pedsim-fixed-co "$PEDSIM_FIXED_CO")
  translate_pedsim_args args "$@"
  bash "$PEDSIM_SCRIPT" "${args[@]}"
}
run_kinship(){
  fast_preflight kinship

  # lowpass_ibis_functions.sh is a library file, not a standalone executable.
  # The kinship entry point is run_ibis_only_workflow(), so main.sh must source
  # the library and call that function directly.
  check_script "$LOWPASS_IBIS_FUNCTIONS"

  export OUTPUT_DIR="$OUT_DIR"
  export OUT_DIR TMP_DIR LOG_DIR PROJECT_DIR

  export IBIS_ONLY=1
  export IBIS_INPUT="${IBIS_INPUT:-}"
  export IBIS_INPUT_FORMAT="${IBIS_INPUT_FORMAT:-auto}"
  export IBIS_EXTRACT="${IBIS_EXTRACT:-${SNP_OUT:-}}"
  export IBIS_OUT_PREFIX="${IBIS_OUT_PREFIX:-$OUT_DIR/kinship/ibisOut}"
  export IBIS_WORK_DIR="${IBIS_WORK_DIR:-}"

  export IBIS_PLINK2="${IBIS_PLINK2:-${PLINK2:-plink2}}"
  export IBIS_BIN="${IBIS_BIN:-}"
  export IBIS_ADD_MAP="${IBIS_ADD_MAP:-}"
  export IBIS_MAP_FILE="${IBIS_MAP_FILE:-${MAP_FILE:-}}"
  export IBIS_ADD_MAP_ENABLED="${IBIS_ADD_MAP_ENABLED:-1}"

  export IBIS_THREADS="${IBIS_THREADS:-${THREADS:-4}}"
  export IBIS_MIN_L="${IBIS_MIN_L:-7}"
  export IBIS_MT="${IBIS_MT:-0.004}"
  export IBIS_ER="${IBIS_ER:-0.004}"
  export IBIS_SET_ALL_VAR_IDS="${IBIS_SET_ALL_VAR_IDS:-@:#}"

  export IBIS_KEEP_TEMP="${IBIS_KEEP_TEMP:-0}"
  export IBIS_PRINT_CMD_ONLY="${IBIS_PRINT_CMD_ONLY:-0}"
  export IBIS_SEG_LENGTH_COL="${IBIS_SEG_LENGTH_COL:-9}"
  export IBIS_SEG_EXPECTED_NCOL="${IBIS_SEG_EXPECTED_NCOL:-9}"
  export IBIS_COEF_EXPECTED_NCOL="${IBIS_COEF_EXPECTED_NCOL:-2}"
  export IBIS_COEF_HEADER_PATTERN="${IBIS_COEF_HEADER_PATTERN:-Individual1}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input|--ibis-input) export IBIS_INPUT="$2"; shift 2 ;;
      --input-format|--ibis-input-format) export IBIS_INPUT_FORMAT="$2"; shift 2 ;;
      --snps|--extract|--ibis-extract) export IBIS_EXTRACT="$2"; shift 2 ;;
      --out-prefix|--ibis-out-prefix) export IBIS_OUT_PREFIX="$2"; shift 2 ;;
      --work-dir|--ibis-work-dir) export IBIS_WORK_DIR="$2"; shift 2 ;;
      --ibis-no-add-map) export IBIS_ADD_MAP_ENABLED=0; shift ;;
      --ibis-add-map-enabled) export IBIS_ADD_MAP_ENABLED="$2"; shift 2 ;;
      --ibis-keep-temp) export IBIS_KEEP_TEMP=1; shift ;;
      --ibis-print-cmd-only) export IBIS_PRINT_CMD_ONLY=1; shift ;;
      --threads|--ibis-threads) export IBIS_THREADS="$2"; shift 2 ;;
      --min-l|--ibis-min-l) export IBIS_MIN_L="$2"; shift 2 ;;
      --mt|--ibis-mt) export IBIS_MT="$2"; shift 2 ;;
      --er|--ibis-er) export IBIS_ER="$2"; shift 2 ;;
      *) die "unknown kinship option: $1" ;;
    esac
  done

  [[ -n "$IBIS_INPUT" ]] || die "kinship requires IBIS_INPUT in config or --input FILE/PREFIX"
  [[ -n "$IBIS_BIN" ]] || die "IBIS_BIN is empty"

  if [[ -n "$IBIS_EXTRACT" && ! -s "$IBIS_EXTRACT" ]]; then
    warn "IBIS_EXTRACT is set but file does not exist; disabling extract: $IBIS_EXTRACT"
    export IBIS_EXTRACT=""
  fi

  # shellcheck source=/dev/null
  source "$LOWPASS_IBIS_FUNCTIONS"
  declare -F run_ibis_only_workflow >/dev/null || die "run_ibis_only_workflow() not found in $LOWPASS_IBIS_FUNCTIONS"
  run_ibis_only_workflow
}
run_lowpass_merge(){
  fast_preflight lowpass-merge
  local n="${1:-}"
  [[ -n "$n" ]] || die "lowpass-merge requires simulation number"

  # run_merge_lowpass_units.sh has been inlined here and is no longer needed.
  # Original logic:
  #   source ./lowpass_ibis_functions.sh
  #   init_lowpass_collection "$n"
  #   process_all_units_for_sim "$n"
  #   collect_lowpass_units "$n"
  check_script "$LOWPASS_IBIS_FUNCTIONS"
  lowpass_functions_ok || die "lowpass-merge requires init_lowpass_collection(), process_all_units_for_sim(), and collect_lowpass_units() in $LOWPASS_IBIS_FUNCTIONS"
  [[ "$(lowpass_merge_status_code)" == 0 ]] || warn "lowpass-merge precheck did not fully pass; continuing because the lowpass module may resolve some paths internally. Run 'doctor lowpass' for details."

  export LOWPASS_CONFIG="${CONFIG_FILE:-}"
  export OUTPUT_DIR="$OUT_DIR"
  export OUT_DIR TMP_DIR LOG_DIR PROJECT_DIR
  export HIGHPASS_PREFIX_TEMPLATE="${HIGHPASS_PREFIX_TEMPLATE:-}"
  export GENOTYPE_FILE_LIST="${GENOTYPE_FILE_LIST:-}"
  export SNP_KEEP_FILE_LIST="${SNP_KEEP_FILE_LIST:-}"
  export INCLUDE_FAM="${INCLUDE_FAM:-}"
  export OVERLAP_SNP="${OVERLAP_SNP:-}"
  export MAP_FILE="${MAP_FILE:-${IBIS_MAP_FILE:-}}"
  export SIM_DIR="${SIM_DIR:-}"
  export PLINK="${PLINK:-}"
  export PLINK2="${PLINK2:-}"
  export IBIS_BIN="${IBIS_BIN:-}"
  export IBIS_ADD_MAP="${IBIS_ADD_MAP:-}"
  export IBIS_MAP_FILE="${IBIS_MAP_FILE:-}"
  export IBIS_THREADS="${IBIS_THREADS:-${THREADS:-4}}"

  echo "########################################"
  echo "Running sim=$n"
  echo "RUN_TAG=${RUN_TAG:-}"
  echo "RUN_ID=${RUN_ID:-}"
  echo "########################################"

  # shellcheck source=/dev/null
  source "$LOWPASS_IBIS_FUNCTIONS"

  declare -F init_lowpass_collection >/dev/null || die "init_lowpass_collection() was not found after sourcing $LOWPASS_IBIS_FUNCTIONS"
  declare -F process_all_units_for_sim >/dev/null || die "process_all_units_for_sim() was not found after sourcing $LOWPASS_IBIS_FUNCTIONS"
  declare -F collect_lowpass_units >/dev/null || die "collect_lowpass_units() was not found after sourcing $LOWPASS_IBIS_FUNCTIONS"

  init_lowpass_collection "$n"
  process_all_units_for_sim "$n"
  collect_lowpass_units "$n"
}


# ---------- evaluate module ----------
eval_abs_path(){
  local x="$1"
  [[ -n "$x" ]] || return 1
  [[ "$x" = /* ]] && { echo "$x"; return 0; }
  if [[ -e "$x" || -e "${x}.raw.seg" || -e "${x}.segcoef.tsv" || -e "${x}.coef" ]]; then
    echo "$PWD/$x"
  else
    echo "$PROJECT_DIR/$x"
  fi
}

eval_pick_file(){
  local src="$1" kind="${2:-auto}" label="${3:-input}"
  [[ -n "$src" ]] || die "$label is empty"
  src="$(eval_abs_path "$src")"

  if [[ -s "$src" ]]; then echo "$src"; return 0; fi

  # Treat as output prefix first.
  local cand
  for cand in \
    "${src}.segcoef.tsv" \
    "${src}.raw.seg" \
    "${src}.coef" \
    "${src}.raw.seg.all.tsv" \
    "${src}.coef.all.tsv" \
    "${src}.segcoef.all.tsv"; do
    [[ -s "$cand" ]] && { echo "$cand"; return 0; }
  done

  if [[ -d "$src" ]]; then
    case "$kind" in
      kinship|truth|ibis|ibis-only)
        # Truth normally comes from the kinship/IBIS-only output, not from lowpass_merge.
        cand=$(find "$src" -type f \
          \( -path '*/kinship/*' -o -name '*ibisOut.segcoef.tsv' -o -name '*.segcoef.tsv' \) \
          ! -path '*/lowpass_merge/*' \
          ! -path '*/evaluate/*' \
          2>/dev/null | sort | tail -n 1 || true)
        [[ -n "$cand" && -s "$cand" ]] && { echo "$cand"; return 0; }
        ;;
      lowpass-merge|prediction|pred|lowpass)
        # Prediction from lowpass-merge should prefer the combined collection output.
        cand=$(find "$src" -type f \
          \( -name '*.segcoef.all.tsv' -o -name '*.raw.seg.all.tsv' -o -name '*.coef.all.tsv' \) \
          2>/dev/null | sort | tail -n 1 || true)
        [[ -n "$cand" && -s "$cand" ]] && { echo "$cand"; return 0; }
        cand=$(find "$src" -type f \
          \( -name '*.segcoef.tsv' -o -name '*.raw.seg' -o -name '*.coef' \) \
          2>/dev/null | sort | tail -n 1 || true)
        [[ -n "$cand" && -s "$cand" ]] && { echo "$cand"; return 0; }
        ;;
      *)
        cand=$(find "$src" -type f \( \
          -name '*.segcoef.all.tsv' -o \
          -name '*.raw.seg.all.tsv' -o \
          -name '*.coef.all.tsv' -o \
          -name '*.segcoef.tsv' -o \
          -name '*.raw.seg' -o \
          -name '*.coef' \
        \) ! -path '*/evaluate/*' 2>/dev/null | sort | tail -n 1 || true)
        [[ -n "$cand" && -s "$cand" ]] && { echo "$cand"; return 0; }
        ;;
    esac
  fi

  die "could not resolve $label file from: $src"
}

eval_normalize_pairs(){
  local in_file="$1" out_file="$2" label="$3"
  [[ -s "$in_file" ]] || die "$label file missing or empty: $in_file"
  mkdir -p "$(dirname "$out_file")"

  awk -v label="$label" -v pair_order="${EVAL_PAIR_ORDER:-sort}" '
    BEGIN{FS=OFS="\t"; cutoff=0}
    function isnum(x){return x ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/}
    function normname(x){x=tolower(x); gsub(/[^a-z0-9]+/,"_",x); return x}
    function pairkey(a,b, x){
      if (pair_order == "keep") return a OFS b
      return (a <= b ? a OFS b : b OFS a)
    }
    function addpair(a,b,total,nseg,coef, key, parts){
      if (a=="" || b=="" || a==b) return
      key=pairkey(a,b)
      split(key,parts,OFS)
      id1[key]=parts[1]; id2[key]=parts[2]
      if (isnum(total)) total_cm[key]+=total+0
      if (isnum(nseg)) n_segments[key]+=nseg+0
      if (isnum(coef)) {coef_sum[key]+=coef+0; coef_n[key]++}
      seen[key]=1
    }
    NR==1{
      header=0
      for(i=1;i<=NF;i++){
        n=normname($i); col[n]=i
        if (n ~ /individual|sample|iid|id1|id2|unit_tag|seg_total|seg_n/) header=1
      }
      if(header){
        id1c=col["individual1"]?col["individual1"]:(col["id1"]?col["id1"]:(col["iid1"]?col["iid1"]:(col["sample1"]?col["sample1"]:0)))
        id2c=col["individual2"]?col["individual2"]:(col["id2"]?col["id2"]:(col["iid2"]?col["iid2"]:(col["sample2"]?col["sample2"]:0)))
        if(id1c==0 && col["unit_tag"]==1 && NF>=3){id1c=2; id2c=3}
        if(id1c==0 && NF>=2){id1c=1; id2c=2}
        totalc=col["seg_total_cm"]?col["seg_total_cm"]:(col["total_cm"]?col["total_cm"]:(col["ibd_cm"]?col["ibd_cm"]:0))
        nsegc=col["seg_n_segments"]?col["seg_n_segments"]:(col["n_segments"]?col["n_segments"]:(col["nseg"]?col["nseg"]:0))
        coefc=col["kinship"]?col["kinship"]:(col["coef"]?col["coef"]:(col["pi_hat"]?col["pi_hat"]:0))
        next
      } else {
        id1c=1; id2c=2; totalc=(NF>=9?9:0); nsegc=0; coefc=0
      }
    }
    NF<2{next}
    {
      a=$(id1c? id1c:1); b=$(id2c? id2c:2)
      total=(totalc && totalc<=NF ? $(totalc) : "")
      nseg=(nsegc && nsegc<=NF ? $(nsegc) : "")
      coef=(coefc && coefc<=NF ? $(coefc) : "")
      # Raw IBIS .seg files usually have segment length in column 9.
      if(total=="" && NF>=9 && isnum($9)) {total=$9; nseg=1}
      addpair(a,b,total,nseg,coef)
    }
    END{
      print "pair_id","id1","id2",label"_total_cM",label"_n_segments",label"_coef"
      for(k in seen){
        coef="NA"; if(coef_n[k]>0) coef=coef_sum[k]/coef_n[k]
        print id1[k]":"id2[k], id1[k], id2[k], total_cm[k]+0, n_segments[k]+0, coef
      }
    }
  ' "$in_file" | sort -k1,1 > "$out_file"
}

eval_merge_and_metrics(){
  local truth_pairs="$1" pred_pairs="$2" out_prefix="$3"
  local merged="${out_prefix}.merged.ibis.tsv"
  local metrics="${out_prefix}.metrics.tsv"
  local summary="${out_prefix}.summary.tsv"
  local cutoff="${EVAL_REL_CUTOFF_CM:-0}"

  awk -v cutoff="$cutoff" -v merged="$merged" -v metrics="$metrics" -v summary="$summary" '
    BEGIN{FS=OFS="\t"}
    FNR==NR{
      if(FNR==1) next
      t_id1[$1]=$2; t_id2[$1]=$3; t_cm[$1]=$4+0; t_n[$1]=$5+0; t_coef[$1]=$6; keys[$1]=1; next
    }
    {
      if(FNR==1) next
      p_id1[$1]=$2; p_id2[$1]=$3; p_cm[$1]=$4+0; p_n[$1]=$5+0; p_coef[$1]=$6; keys[$1]=1
    }
    END{
      print "pair_id","id1","id2","truth_total_cM","truth_n_segments","truth_coef","pred_total_cM","pred_n_segments","pred_coef","truth_related","pred_related","delta_total_cM","call_status" > merged
      for(k in keys){
        id1=(t_id1[k]!=""?t_id1[k]:p_id1[k]); id2=(t_id2[k]!=""?t_id2[k]:p_id2[k])
        tc=t_cm[k]+0; pc=p_cm[k]+0
        tr=(tc>cutoff?1:0); pr=(pc>cutoff?1:0)
        if(tr==1 && pr==1){status="TP"; TP++}
        else if(tr==0 && pr==1){status="FP"; FP++}
        else if(tr==1 && pr==0){status="FN"; FN++}
        else {status="TN"; TN++}
        d=pc-tc; mse+=d*d; mae+=(d<0?-d:d); n++
        if(tr==1){mse_rel+=d*d; mae_rel+=(d<0?-d:d); n_rel++}
        print k,id1,id2,tc,t_n[k]+0,(t_coef[k]==""?"NA":t_coef[k]),pc,p_n[k]+0,(p_coef[k]==""?"NA":p_coef[k]),tr,pr,d,status > merged
      }
      precision=(TP+FP>0?TP/(TP+FP):"NA")
      recall=(TP+FN>0?TP/(TP+FN):"NA")
      f1=(precision != "NA" && recall != "NA" && precision+recall>0 ? 2*precision*recall/(precision+recall) : "NA")
      specificity=(TN+FP>0?TN/(TN+FP):"NA")
      print "metric","value" > metrics
      print "TP",TP+0 > metrics; print "FP",FP+0 > metrics; print "FN",FN+0 > metrics; print "TN",TN+0 > metrics
      print "precision",precision > metrics; print "recall",recall > metrics; print "f1",f1 > metrics; print "specificity",specificity > metrics
      print "n_pairs",n+0 > metrics; print "mse_total_cM",(n>0?mse/n:"NA") > metrics; print "mae_total_cM",(n>0?mae/n:"NA") > metrics
      print "n_truth_related",n_rel+0 > metrics; print "mse_total_cM_truth_related",(n_rel>0?mse_rel/n_rel:"NA") > metrics; print "mae_total_cM_truth_related",(n_rel>0?mae_rel/n_rel:"NA") > metrics
      print "key","value" > summary
      print "merged",merged > summary; print "metrics",metrics > summary; print "truth_pairs","'"$truth_pairs"'" > summary; print "pred_pairs","'"$pred_pairs"'" > summary; print "related_cutoff_cM",cutoff > summary
    }
  ' "$truth_pairs" "$pred_pairs"
}

run_evaluate(){
  fast_preflight evaluate
  local truth_src="${EVAL_TRUTH:-}" pred_src="${EVAL_PRED:-}" out_prefix="${EVAL_OUT_PREFIX:-$OUT_DIR/evaluate/run1}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --truth) truth_src="$2"; shift 2 ;;
      --truth-type) export EVAL_TRUTH_TYPE="$2"; shift 2 ;;
      --pred|--prediction) pred_src="$2"; shift 2 ;;
      --pred-type|--prediction-type) export EVAL_PRED_TYPE="$2"; shift 2 ;;
      --out-prefix) out_prefix="$2"; shift 2 ;;
      --rel-cutoff-cm|--cutoff-cm) export EVAL_REL_CUTOFF_CM="$2"; shift 2 ;;
      *) die "unknown evaluate option: $1" ;;
    esac
  done
  [[ -n "$truth_src" ]] || die "evaluate requires EVAL_TRUTH or --truth"
  [[ -n "$pred_src" ]] || die "evaluate requires EVAL_PRED or --pred"

  out_prefix="$(eval_abs_path "$out_prefix")"
  mkdir -p "$(dirname "$out_prefix")"

  local truth_file pred_file truth_pairs pred_pairs
  truth_file=$(eval_pick_file "$truth_src" "${EVAL_TRUTH_TYPE:-auto}" "EVAL_TRUTH")
  pred_file=$(eval_pick_file "$pred_src" "${EVAL_PRED_TYPE:-auto}" "EVAL_PRED")
  if [[ "$truth_file" == "$pred_file" ]]; then
    die "EVAL_TRUTH and EVAL_PRED resolved to the same file: $truth_file. Set EVAL_TRUTH to the kinship truth output prefix/file and EVAL_PRED to the lowpass-merge prediction output prefix/dir."
  fi
  truth_pairs="${out_prefix}.truth.pairs.tsv"
  pred_pairs="${out_prefix}.pred.pairs.tsv"

  info "running evaluate"
  info "truth_file=$truth_file"
  info "pred_file=$pred_file"
  info "out_prefix=$out_prefix"

  eval_normalize_pairs "$truth_file" "$truth_pairs" "truth"
  eval_normalize_pairs "$pred_file" "$pred_pairs" "pred"
  eval_merge_and_metrics "$truth_pairs" "$pred_pairs" "$out_prefix"

  echo "========================================"
  echo "[DONE] evaluate finished"
  echo "truth_pairs=${truth_pairs}"
  echo "pred_pairs=${pred_pairs}"
  echo "merged=${out_prefix}.merged.ibis.tsv"
  echo "metrics=${out_prefix}.metrics.tsv"
  echo "summary=${out_prefix}.summary.tsv"
  echo "========================================"
}

run_workflow(){
  local name="${1:-${WORKFLOW_NAME:-simulate-kinship}}"; [[ $# -gt 0 ]] && shift || true
  case "$name" in
    simulate-kinship)
      run_snps
      run_simulate
      local sim_vcf="${WORKFLOW_IBIS_INPUT:-${PEDSIM_OUTPUT_VCF:-}}"
      if [[ -z "$sim_vcf" ]]; then
        sim_vcf="$(find "$OUT_DIR" -maxdepth 2 -type f \( -name "*.vcf.gz" -o -name "*.bcf" -o -name "*.bed" \) 2>/dev/null | sort | tail -1 || true)"
      fi
      [[ -n "$sim_vcf" ]] || die "workflow could not infer simulated VCF/BCF/PLINK input; set WORKFLOW_IBIS_INPUT or run kinship manually"
      run_kinship --input "$sim_vcf" --snps "$SNP_OUT" --out-prefix "${WORKFLOW_IBIS_OUT_PREFIX:-$OUT_DIR/kinship/${SIM_DEF_NAME}_ibisOut}"
      ;;
    *) die "unknown workflow: $name" ;;
  esac
}

# ---------- init/templates/profile ----------
write_config_file(){ local f="$1"; shift; mkdir -p "$(dirname "$f")"; cat > "$f"; info "wrote $f"; }
cmd_profile(){
  local sub="${1:-}"; shift || true; mkdir -p "$HOME/.mixdetect/profiles"
  case "$sub" in
    init)
      local out="$HOME/.mixdetect/profiles/default.txt" tool_root="$SCRIPT_DIR" force=0 name=""
      while [[ $# -gt 0 ]]; do case "$1" in --config) out="$2"; shift 2;; --tool-root) tool_root="$2"; shift 2;; --name) name="$2"; shift 2;; --force) force=1; shift;; *) die "unknown profile init option: $1";; esac; done
      [[ -n "$name" ]] && out="$HOME/.mixdetect/profiles/${name}.txt"
      [[ ! -e "$out" || "$force" == 1 ]] || die "profile exists: $out; use --force"
      write_config_file "$out" <<EOF2
TOOL_ROOT=$tool_root
BIN_DIR=$tool_root/bin
RESOURCE_DIR=$tool_root/resources
BCFTOOLS=$tool_root/bin/bcftools
PLINK=$tool_root/bin/plink
PLINK2=$tool_root/bin/plink2
PEDSIM_BIN=$tool_root/bin/ped-sim
IBIS_BIN=$tool_root/bin/ibis
IBIS_ADD_MAP=$tool_root/bin/add-map
BEAGLE_JAR=$tool_root/bin/beagle.jar
EOF2
      ;;
    list) ls -1 "$HOME/.mixdetect/profiles"/*.txt 2>/dev/null | sed 's#.*/##;s#\.txt$##' || true ;;
    show) local name="${1:-}"; [[ -n "$name" ]] || die "profile show requires name"; cat "$HOME/.mixdetect/profiles/${name}.txt" ;;
    *) die "usage: profile init|list|show" ;;
  esac
}
cmd_config(){
  local type="${1:-}"; shift || true
  local out="" include="../config.txt"
  while [[ $# -gt 0 ]]; do case "$1" in --config) out="$2"; shift 2;; --include) include="$2"; shift 2;; *) die "unknown config option: $1";; esac; done
  [[ -n "$type" && -n "$out" ]] || die "usage: config <type> --config FILE [--include FILE]"
  mkdir -p "$(dirname "$out")"
  case "$type" in
    snps) cat > "$out" <<EOF2
INCLUDE=$include
SNP_INPUT=
SNP_GP=0.99
SNP_BF=50
SNP_ID_STYLE=chr
SNP_SAMPLE_MODE=any
SNP_OUT=results/snps.GP099_BF50.txt
EOF2
      ;;
    phase) cat > "$out" <<EOF2
INCLUDE=$include
PHASE_CHR=1
PHASE_XMX=500g
EOF2
      ;;
    simulate) cat > "$out" <<EOF2
INCLUDE=$include
SIM_RELATIONSHIP=cousin
SIM_DEGREE=3
SIM_HALF=0
SIM_COPIES=1
SIM_DEF_NAME=cousin_d3_full
SIM_SEED=42
EOF2
      ;;
    kinship) cat > "$out" <<EOF2
INCLUDE=$include
IBIS_INPUT=
IBIS_OUT_PREFIX=results/kinship/ibisOut
IBIS_THREADS=4
EOF2
      ;;
    workflow) cat > "$out" <<EOF2
INCLUDE=$include
WORKFLOW_NAME=simulate-kinship
SIM_RELATIONSHIP=cousin
SIM_DEGREE=3
SNP_GP=0.99
SNP_BF=50
EOF2
      ;;
    evaluate) cat > "$out" <<EOF2
INCLUDE=$include
EVAL_TRUTH_TYPE=kinship
EVAL_TRUTH=results/kinship/truth_ibisOut
EVAL_PRED_TYPE=lowpass-merge
EVAL_PRED=results/lowpass_merge
EVAL_OUT_PREFIX=results/evaluate/run1
EVAL_REL_CUTOFF_CM=0
EOF2
      ;;
    parallel) cat > "$out" <<EOF2
INCLUDE=$include
PARALLEL_WORKFLOW=lowpass-merge
PARALLEL_ARRAY=1-10
LOCAL_JOBS=4
SLURM_CPUS=4
SLURM_MEM=40G
SLURM_TIME=08:00:00
EOF2
      ;;
    *) die "unknown config template: $type" ;;
  esac
  info "wrote $out"
}
cmd_init(){
  local cfg="" project="test_project" profile="" founder="" highpass="" panel="" interactive=0
  while [[ $# -gt 0 ]]; do case "$1" in --config) cfg="$2"; shift 2;; --project) project="$2"; shift 2;; --profile) profile="$2"; shift 2;; --founder-vcf) founder="$2"; shift 2;; --highpass-vcf) highpass="$2"; shift 2;; --snp-panel) panel="$2"; shift 2;; --interactive) interactive=1; shift;; *) die "unknown init option: $1";; esac; done
  if [[ "$interactive" == 1 ]]; then
    read -r -p "Project name [$project]: " x; [[ -n "$x" ]] && project="$x"
    read -r -p "Config file [$project/config.txt]: " cfg; [[ -z "$cfg" ]] && cfg="$project/config.txt"
    read -r -p "PROFILE []: " profile
    read -r -p "FOUNDER_VCF []: " founder
    read -r -p "HIGH_PASS_VCF []: " highpass
    read -r -p "SNP_PANEL_LIST []: " panel
  fi
  [[ -n "$cfg" ]] || cfg="$project/config.txt"
  local pdir; pdir="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd || pwd)/$(basename "$(dirname "$cfg")")"
  mkdir -p "$(dirname "$cfg")" "$(dirname "$cfg")/configs" "$(dirname "$cfg")/input" "$(dirname "$cfg")/results" "$(dirname "$cfg")/tmp" "$(dirname "$cfg")/logs"
  cat > "$cfg" <<EOF2
PROFILE=$profile
PROJECT_NAME=$project
PROJECT_DIR=$(cd "$(dirname "$cfg")" && pwd)
OUT_DIR=$(cd "$(dirname "$cfg")" && pwd)/results
TMP_DIR=$(cd "$(dirname "$cfg")" && pwd)/tmp
LOG_DIR=$(cd "$(dirname "$cfg")" && pwd)/logs
TOOL_ROOT=$SCRIPT_DIR
FOUNDER_VCF=$founder
HIGH_PASS_VCF=$highpass
SNP_PANEL_LIST=$panel
SNP_GP=0.99
SNP_BF=50
SNP_ID_STYLE=chr
SIM_RELATIONSHIP=cousin
SIM_DEGREE=3
SIM_HALF=0
SIM_COPIES=1
SIM_DEF_NAME=cousin_d3_full
SIM_SEED=42
FAST_PREFLIGHT=1
STAGE_TO_LOCAL=auto
EOF2
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config snps --config configs/snps.GP099_BF50.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config phase --config configs/phase.chr1.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config simulate --config configs/simulate.cousin_d3.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config kinship --config configs/kinship.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config workflow --config configs/workflow.simulate_kinship.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config parallel --config configs/parallel.lowpass_merge.txt --include ../$(basename "$cfg") >/dev/null)
  (cd "$(dirname "$cfg")" && bash "$SELF_PATH" config evaluate --config configs/evaluate.txt --include ../$(basename "$cfg") >/dev/null)
  info "initialized project config: $cfg"
}

# ---------- parallel ----------
expand_array(){
  local spec="$1" part a b i
  echo "$spec" | tr ',' '\n' | while read -r part; do
    [[ -z "$part" ]] && continue
    if [[ "$part" == *-* ]]; then a="${part%-*}"; b="${part#*-}"; for ((i=a;i<=b;i++)); do echo "$i"; done
    else echo "$part"; fi
  done
}
run_parallel_task(){
  local workflow="$1" tid="$2"
  export TASK_ID="$tid" SLURM_ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:-$tid}"
  case "$workflow" in
    phase) run_with_status "$workflow" "$tid" run_phase --chr "$tid" ;;
    lowpass-merge) run_with_status "$workflow" "$tid" run_lowpass_merge "$tid" ;;
    simulate) export SIM_SEED="$(( ${BASE_SEED:-${SIM_SEED:-42}} + tid ))"; run_with_status "$workflow" "$tid" run_simulate ;;
    kinship) run_with_status "$workflow" "$tid" run_kinship ;;
    evaluate) run_with_status "$workflow" "$tid" run_evaluate ;;
    simulate-kinship) export SIM_SEED="$(( ${BASE_SEED:-${SIM_SEED:-42}} + tid ))"; run_with_status "$workflow" "$tid" run_workflow simulate-kinship ;;
    *) die "unknown parallel workflow: $workflow" ;;
  esac
}
cmd_parallel(){
  local sub="${1:-}"; shift || true
  local workflow="${PARALLEL_WORKFLOW:-lowpass-merge}" array="${PARALLEL_ARRAY:-1-1}" jobs="${LOCAL_JOBS:-1}" cpus="${SLURM_CPUS:-4}" mem="${SLURM_MEM:-40G}" time="${SLURM_TIME:-08:00:00}" dry=0
  while [[ $# -gt 0 ]]; do case "$1" in --workflow) workflow="$2"; shift 2;; --array) array="$2"; shift 2;; --jobs) jobs="$2"; shift 2;; --cpus) cpus="$2"; shift 2;; --mem) mem="$2"; shift 2;; --time) time="$2"; shift 2;; --dry-run) dry=1; shift;; *) break;; esac; done
  case "$sub" in
    local)
      export -f run_parallel_task run_with_status run_phase run_lowpass_merge run_simulate run_kinship run_evaluate run_workflow run_snps run_def fast_preflight check_script check_file_if_set die info warn translate_pedsim_args base_pedsim_args
      export CONFIG_FILE NO_PREFLIGHT FORCE_STAGE LOCAL_SCRATCH_OVERRIDE SCRIPT_DIR TOOL_ROOT BIN_DIR RESOURCE_DIR OUT_DIR TMP_DIR LOG_DIR FAST_PREFLIGHT SNPLIST_SCRIPT PEDSIM_SCRIPT LOWPASS_IBIS_FUNCTIONS LOWPASS_MERGE_SCRIPT BCFTOOLS PLINK PLINK2 PEDSIM_BIN IBIS_BIN IBIS_ADD_MAP BEAGLE_JAR PEDSIM_MAP PEDSIM_INTF IBIS_MAP_FILE PHASE_MAP_TEMPLATE SNP_INPUT SNP_GP SNP_BF SNP_ID_STYLE SNP_SAMPLE_MODE SNP_OUT SIM_RELATIONSHIP SIM_DEGREE SIM_HALF SIM_COPIES SIM_DEF_NAME SIM_SEED BASE_SEED IBIS_THREADS IBIS_MIN_L IBIS_MT IBIS_ER IBIS_SET_ALL_VAR_IDS HIGHPASS_PREFIX_TEMPLATE GENOTYPE_FILE_LIST SNP_KEEP_FILE_LIST INCLUDE_FAM OVERLAP_SNP MAP_FILE SIM_DIR RUN_TAG RUN_ID THREADS EVAL_TRUTH_TYPE EVAL_TRUTH EVAL_PRED_TYPE EVAL_PRED EVAL_OUT_PREFIX EVAL_REL_CUTOFF_CM EVAL_PAIR_ORDER
      expand_array "$array" | xargs -I{} -P "$jobs" bash -c 'run_parallel_task "$0" "$1"' "$workflow" {}
      ;;
    slurm)
      mkdir -p "$LOG_DIR/slurm"
      local sb="$LOG_DIR/slurm/${workflow}.sbatch"
      cat > "$sb" <<EOF2
#!/usr/bin/env bash
#SBATCH --job-name=mix_${workflow}
#SBATCH --array=${array}
#SBATCH --cpus-per-task=${cpus}
#SBATCH --mem=${mem}
#SBATCH --time=${time}
#SBATCH --output=${LOG_DIR}/slurm/${workflow}.%A.%a.out
#SBATCH --error=${LOG_DIR}/slurm/${workflow}.%A.%a.err
set -euo pipefail
bash "$SELF_PATH" --config "$CONFIG_FILE" parallel task "$workflow" "\${SLURM_ARRAY_TASK_ID}"
EOF2
      info "sbatch written: $sb"
      [[ "$dry" == 1 ]] || sbatch "$sb"
      ;;
    task) local wf="${1:-$workflow}" tid="${2:-${SLURM_ARRAY_TASK_ID:-}}"; [[ -n "$tid" ]] || die "parallel task requires task id"; run_parallel_task "$wf" "$tid" ;;
    status)
      local status_dir="$LOG_DIR/status" done_n=0 failed=() missing=() id
      for id in $(expand_array "$array"); do
        if [[ -s "$status_dir/${workflow}.${id}.done" ]]; then done_n=$((done_n+1)); elif [[ -s "$status_dir/${workflow}.${id}.failed" ]]; then failed+=("$id"); else missing+=("$id"); fi
      done
      echo "workflow: $workflow"; echo "array: $array"; echo "DONE: $done_n"; echo "FAILED: ${failed[*]:-}"; echo "MISSING: ${missing[*]:-}"
      ;;
    *) die "usage: parallel local|slurm|task|status" ;;
  esac
}

# ---------- global args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --no-preflight) NO_PREFLIGHT=1; shift ;;
    --stage) FORCE_STAGE=1; shift ;;
    --no-stage) FORCE_STAGE=0; shift ;;
    --local-scratch) LOCAL_SCRATCH_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 1; }; shift || true

case "$cmd" in
  init) cmd_init "$@"; exit 0 ;;
  config) cmd_config "$@"; exit 0 ;;
  profile) cmd_profile "$@"; exit 0 ;;
esac

load_all_config
setup_staging "$cmd"

case "$cmd" in
  doctor) doctor "$@" ;;
  snps|snplist|snp-list) run_snps "$@" ;;
  phase|phase-only) run_phase "$@" ;;
  def|make-def) run_def "$@" ;;
  simulate|pedsim) run_simulate "$@" ;;
  kinship|ibis|ibis-only) run_kinship "$@" ;;
  lowpass-merge|merge-lowpass) run_lowpass_merge "$@" ;;
  evaluate|eval) run_evaluate "$@" ;;
  workflow) run_workflow "$@" ;;
  parallel) cmd_parallel "$@" ;;
  help|-h|--help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
