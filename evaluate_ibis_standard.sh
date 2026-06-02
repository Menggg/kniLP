#!/usr/bin/env bash
set -euo pipefail

VERSION="2026-05-29"

# evaluate_ibis_standard.sh
#
# Standalone evaluator for mix_detect standard IBIS outputs.
#
# Supported input sources only:
#   1) kinship module standard output:
#        *.segcoef.tsv
#   2) lowpass-merge module standard collection output:
#        lowpass_merge.sim_*.segcoef.all.tsv
#        or per-unit *.segcoef.tsv under lowpass_merge directories
#
# External raw IBIS formats are intentionally not supported here.
# External data should first be converted by mix_detect kinship module.
#
# Main outputs:
#   <out-prefix>.truth.normalized.tsv
#   <out-prefix>.pred.normalized.tsv
#   <out-prefix>.merged.ibis.tsv
#   <out-prefix>.pair_compare.tsv
#   <out-prefix>.summary.tsv
#   <out-prefix>.by_group_summary.tsv

info(){ echo "[eval] $*" >&2; }
warn(){ echo "[eval][WARN] $*" >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }

usage(){ cat >&2 <<'USAGE'
Usage:
  bash evaluate_ibis_standard.sh \
    --truth-type kinship|lowpass-merge \
    --truth FILE_OR_DIR \
    --pred-type kinship|lowpass-merge \
    --pred FILE_OR_DIR \
    --out-prefix OUT_PREFIX [options]

Required:
  --truth-type TYPE       kinship or lowpass-merge
  --truth PATH            standard output file or directory from that module
  --pred-type TYPE        kinship or lowpass-merge
  --pred PATH             standard output file or directory from that module
  --out-prefix PREFIX     output prefix

Options:
  --truth-sim-id ID       force sim_id for all truth rows
  --pred-sim-id ID        force sim_id for all pred rows
  --truth-unit LABEL      force unit_label for all truth rows
  --pred-unit LABEL       force unit_label for all pred rows
  --related-cm FLOAT      total cM threshold for related classification [default: 7]
  --min-cm FLOAT          minimum segment total cM to count as detected [default: 0]
  --all-pairs FILE        optional file with all sample pairs: sample1 sample2 [optional]
  --keep-normalized       keep intermediate normalized tables [default: yes]
  -h, --help              show help

Input rules:
  TYPE=kinship:
    PATH can be a single *.segcoef.tsv file or a directory containing such files.

  TYPE=lowpass-merge:
    PATH can be a single lowpass_merge.sim_*.segcoef.all.tsv file,
    a single per-unit *.segcoef.tsv file, or a directory containing these files.

Pair matching:
  Pairs are matched by sim_id + unordered pair_id.
  For pred with multiple lowpass units, statistics are computed per pred_unit_label.
USAGE
}

TRUTH_TYPE=""
PRED_TYPE=""
TRUTH_PATH=""
PRED_PATH=""
OUT_PREFIX=""
TRUTH_SIM_ID=""
PRED_SIM_ID=""
TRUTH_UNIT=""
PRED_UNIT=""
RELATED_CM="7"
MIN_CM="0"
ALL_PAIRS=""
KEEP_NORMALIZED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --truth-type) TRUTH_TYPE="$2"; shift 2 ;;
    --truth) TRUTH_PATH="$2"; shift 2 ;;
    --pred-type) PRED_TYPE="$2"; shift 2 ;;
    --pred) PRED_PATH="$2"; shift 2 ;;
    --out-prefix) OUT_PREFIX="$2"; shift 2 ;;
    --truth-sim-id) TRUTH_SIM_ID="$2"; shift 2 ;;
    --pred-sim-id) PRED_SIM_ID="$2"; shift 2 ;;
    --truth-unit) TRUTH_UNIT="$2"; shift 2 ;;
    --pred-unit) PRED_UNIT="$2"; shift 2 ;;
    --related-cm) RELATED_CM="$2"; shift 2 ;;
    --min-cm) MIN_CM="$2"; shift 2 ;;
    --all-pairs) ALL_PAIRS="$2"; shift 2 ;;
    --keep-normalized) KEEP_NORMALIZED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$TRUTH_TYPE" ]] || die "--truth-type is required"
[[ -n "$PRED_TYPE" ]] || die "--pred-type is required"
[[ -n "$TRUTH_PATH" ]] || die "--truth is required"
[[ -n "$PRED_PATH" ]] || die "--pred is required"
[[ -n "$OUT_PREFIX" ]] || die "--out-prefix is required"

case "$TRUTH_TYPE" in kinship|lowpass-merge) ;; *) die "--truth-type must be kinship or lowpass-merge" ;; esac
case "$PRED_TYPE" in kinship|lowpass-merge) ;; *) die "--pred-type must be kinship or lowpass-merge" ;; esac
[[ -e "$TRUTH_PATH" ]] || die "truth path not found: $TRUTH_PATH"
[[ -e "$PRED_PATH" ]] || die "pred path not found: $PRED_PATH"
[[ -z "$ALL_PAIRS" || -s "$ALL_PAIRS" ]] || die "--all-pairs file missing or empty: $ALL_PAIRS"

mkdir -p "$(dirname "$OUT_PREFIX")"

TRUTH_NORM="${OUT_PREFIX}.truth.normalized.tsv"
PRED_NORM="${OUT_PREFIX}.pred.normalized.tsv"
MERGED_LONG="${OUT_PREFIX}.merged.ibis.tsv"
PAIR_COMPARE="${OUT_PREFIX}.pair_compare.tsv"
SUMMARY="${OUT_PREFIX}.summary.tsv"
BY_GROUP="${OUT_PREFIX}.by_group_summary.tsv"
FILE_LIST_DIR="${OUT_PREFIX}.work"
mkdir -p "$FILE_LIST_DIR"

safe_tag(){ basename "$1" | sed 's/\.segcoef\.all\.tsv$//; s/\.segcoef\.tsv$//; s/\.tsv$//; s/[^A-Za-z0-9._-]/_/g'; }

infer_sim_id_from_path(){
  local f="$1" base sim
  base=$(basename "$f")
  sim=$(echo "$base" | sed -n 's/.*sim[_-]*\([0-9][0-9]*\).*/\1/p' | head -n1)
  if [[ -n "$sim" ]]; then echo "$sim"; else echo "1"; fi
}

infer_unit_from_path(){
  local f="$1" base dir parent
  base=$(basename "$f")
  dir=$(dirname "$f")
  parent=$(basename "$dir")

  if [[ "$base" == lowpass_merge.sim_*.segcoef.all.tsv ]]; then
    echo "all_units"
  elif [[ "$base" == *.segcoef.tsv ]]; then
    safe_tag "$base"
  elif [[ "$parent" == units ]]; then
    safe_tag "$base"
  else
    safe_tag "$parent"
  fi
}

list_standard_files(){
  local type="$1" path="$2" out="$3"
  : > "$out"
  if [[ -f "$path" ]]; then
    case "$path" in
      *.segcoef.tsv|*.segcoef.all.tsv) echo "$path" > "$out" ;;
      *) die "unsupported $type input file; expected *.segcoef.tsv or *.segcoef.all.tsv: $path" ;;
    esac
  elif [[ -d "$path" ]]; then
    if [[ "$type" == "lowpass-merge" ]]; then
      find "$path" -type f \( -name 'lowpass_merge.sim_*.segcoef.all.tsv' -o -name '*.segcoef.tsv' \) | sort > "$out"
    else
      find "$path" -type f -name '*.segcoef.tsv' | sort > "$out"
    fi
  else
    die "input path is neither file nor directory: $path"
  fi
  [[ -s "$out" ]] || die "no standard segcoef files found under: $path"
}

# Normalize either kinship or lowpass-merge standard segcoef tables.
# The standard outputs created by mix_detect use columns including sample pair fields
# and appended segment summary fields: seg_total_cM, seg_n_segments, seg_filled.
# Some files may have generic coef_col1/coef_col2. This normalizer detects columns
# conservatively and emits a stable schema.
normalize_collection(){
  local role="$1" type="$2" path="$3" out="$4" forced_sim="$5" forced_unit="$6"
  local flist="$FILE_LIST_DIR/${role}.files.list"
  list_standard_files "$type" "$path" "$flist"

  info "normalizing $role ($type): $(wc -l < "$flist" | awk '{print $1}') file(s)"

  awk -v role="$role" \
      -v type="$type" \
      -v forced_sim="$forced_sim" \
      -v forced_unit="$forced_unit" \
      -v file_list="$flist" '
    BEGIN {
      FS=OFS="\t"
      print "source_role","source_type","sim_id","unit_label","sample1","sample2","pair_id","coef","seg_total_cM","seg_n_segments","seg_filled","source_file"
    }

    function pairid(a,b) { return (a < b ? a":"b : b":"a) }
    function basename(path, x,n,a) { n=split(path,a,"/"); return a[n] }
    function dirname(path, x) { x=path; sub("/[^/]*$", "", x); if (x==path) return "."; return x }
    function safe(x) { gsub(/[^A-Za-z0-9._-]/,"_",x); return x }
    function infer_sim(path, b,s) {
      b=basename(path)
      if (match(b, /sim[_-]*[0-9]+/)) {
        s=substr(b, RSTART, RLENGTH)
        gsub(/[^0-9]/,"",s)
        return s
      }
      return "1"
    }
    function infer_unit(path, b,d,p) {
      b=basename(path)
      d=dirname(path)
      p=basename(d)
      if (b ~ /^lowpass_merge\.sim_.*\.segcoef\.all\.tsv$/) return "all_units"
      sub(/\.segcoef\.all\.tsv$/,"",b)
      sub(/\.segcoef\.tsv$/,"",b)
      sub(/\.tsv$/,"",b)
      return safe(b)
    }
    function isnum(x) { return x ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/ }
    function lower(x) { return tolower(x) }
    function col(name, fallback, i,l) {
      if (name in h) return h[name]
      l=lower(name)
      if (l in hl) return hl[l]
      return fallback
    }
    function detect_cols(nf,   i,l) {
      delete h; delete hl
      for (i=1;i<=nf;i++) { h[$i]=i; hl[lower($i)]=i }

      c_unit=0
      if ("unit_tag" in h) c_unit=h["unit_tag"]
      else if ("unit_label" in h) c_unit=h["unit_label"]

      c_s1=0; c_s2=0
      # Preferred explicit/common headers.
      split("sample1 sample_1 id1 iid1 individual1 Individual1 coef_col1", a, " ")
      for (i in a) if (a[i] in h && c_s1==0) c_s1=h[a[i]]
      split("sample2 sample_2 id2 iid2 individual2 Individual2 coef_col2", a, " ")
      for (i in a) if (a[i] in h && c_s2==0) c_s2=h[a[i]]

      # If merged lowpass file has unit_tag first and generic coef_col1/2, these are shifted but names are still present.
      if (c_s1==0) c_s1=1
      if (c_s2==0) c_s2=2
      if (c_unit>0 && c_s1==c_unit) c_s1=2
      if (c_unit>0 && c_s2==c_unit) c_s2=3

      c_coef=0
      split("Kinship kinship coef coefficient ibd_coeff relatedness PI_HAT pi_hat", a, " ")
      for (i in a) if (a[i] in h && c_coef==0) c_coef=h[a[i]]

      c_total=0
      split("seg_total_cM total_cm total_cM Total_cM totalIBD seg_col9", a, " ")
      for (i in a) if (a[i] in h && c_total==0) c_total=h[a[i]]

      c_nseg=0
      split("seg_n_segments n_segments nseg", a, " ")
      for (i in a) if (a[i] in h && c_nseg==0) c_nseg=h[a[i]]

      c_filled=0
      if ("seg_filled" in h) c_filled=h["seg_filled"]

      # The mix_detect segcoef.tsv appends these three columns at the end.
      if (c_total==0 && nf>=3) c_total=nf-2
      if (c_nseg==0 && nf>=2) c_nseg=nf-1
      if (c_filled==0 && nf>=1) c_filled=nf
    }

    function emit_file(path,   sim,unit,line,nf,s1,s2,coef,total,nseg,filled) {
      sim=(forced_sim != "" ? forced_sim : infer_sim(path))
      unit=(forced_unit != "" ? forced_unit : infer_unit(path))

      while ((getline line < path) > 0) {
        if (line == "") continue
        nf=split(line, f, FS)
        if (nf < 2) continue

        # Header line: detect columns and skip.
        if (line ~ /(^|\t)(source_role|unit_tag|coef_col1|Individual1|sample1|id1|iid1)(\t|$)/ || f[1] !~ /^[^[:space:]]+$/) {
          for (i=1;i<=nf;i++) $i=f[i]
          detect_cols(nf)
          header_seen=1
          continue
        }

        if (!header_seen) {
          # Fallback for headerless files, although standard files should have a header.
          c_unit=0; c_s1=1; c_s2=2; c_coef=0; c_total=(nf>=3?nf-2:0); c_nseg=(nf>=2?nf-1:0); c_filled=(nf>=1?nf:0)
          header_seen=1
        }

        s1=(c_s1>0 && c_s1<=nf ? f[c_s1] : "")
        s2=(c_s2>0 && c_s2<=nf ? f[c_s2] : "")
        if (c_unit>0 && c_unit<=nf && forced_unit=="" && type=="lowpass-merge") unit=f[c_unit]

        # Skip malformed lines and repeated headers.
        if (s1=="" || s2=="" || s1=="sample1" || s1=="coef_col1" || s1=="Individual1") continue
        if (s1==s2) continue

        coef=(c_coef>0 && c_coef<=nf && isnum(f[c_coef]) ? f[c_coef] : "NA")
        total=(c_total>0 && c_total<=nf && isnum(f[c_total]) ? f[c_total] : 0)
        nseg=(c_nseg>0 && c_nseg<=nf && isnum(f[c_nseg]) ? f[c_nseg] : 0)
        filled=(c_filled>0 && c_filled<=nf && isnum(f[c_filled]) ? f[c_filled] : "NA")

        print role,type,sim,unit,s1,s2,pairid(s1,s2),coef,total,nseg,filled,path
      }
      close(path)
    }

    {
      path=$0
      header_seen=0
      emit_file(path)
    }
  ' "$flist" > "$out"

  [[ -s "$out" ]] || die "failed to normalize $role: $path"
  local n
  n=$(awk 'NR>1{n++} END{print n+0}' "$out")
  [[ "$n" -gt 0 ]] || die "normalized $role has zero data rows: $out"
  info "$role normalized rows: $n -> $out"
}

normalize_collection "truth" "$TRUTH_TYPE" "$TRUTH_PATH" "$TRUTH_NORM" "$TRUTH_SIM_ID" "$TRUTH_UNIT"
normalize_collection "pred" "$PRED_TYPE" "$PRED_PATH" "$PRED_NORM" "$PRED_SIM_ID" "$PRED_UNIT"

# Long merged plotting table.
{
  head -n 1 "$TRUTH_NORM"
  tail -n +2 "$TRUTH_NORM"
  tail -n +2 "$PRED_NORM"
} > "$MERGED_LONG"
info "merged long-format IBIS table: $MERGED_LONG"

# Pair comparison and summaries.
awk -v related_cm="$RELATED_CM" -v min_cm="$MIN_CM" -v all_pairs="$ALL_PAIRS" -v pair_out="$PAIR_COMPARE" -v summary_out="$SUMMARY" -v group_out="$BY_GROUP" '
  BEGIN {
    FS=OFS="\t"
  }
  function pairid(a,b) { return (a < b ? a":"b : b":"a) }
  function isnum(x) { return x ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/ }
  function truth_related(cm) { return (cm+0 >= related_cm ? 1 : 0) }
  function pred_related(cm) { return (cm+0 >= related_cm && cm+0 >= min_cm ? 1 : 0) }
  function abs(x) { return x<0 ? -x : x }

  ARGIND==1 {
    if (FNR==1) next
    sim=$3; unit=$4; pair=$7
    key=sim SUBSEP pair
    truth_seen[key]=1
    truth_sim[key]=sim
    truth_pair[key]=pair
    truth_s1[key]=$5
    truth_s2[key]=$6
    truth_cm[key]=$9+0
    truth_nseg[key]=$10+0
    truth_coef[key]=$8
    truth_file[key]=$12
    all_sims[sim]=1
    all_pairs_seen[sim SUBSEP pair]=1
    next
  }

  ARGIND==2 {
    if (FNR==1) next
    sim=$3; unit=$4; pair=$7
    key=sim SUBSEP unit SUBSEP pair
    pred_seen[key]=1
    pred_sim[key]=sim
    pred_unit[key]=unit
    pred_pair[key]=pair
    pred_s1[key]=$5
    pred_s2[key]=$6
    pred_cm[key]=$9+0
    pred_nseg[key]=$10+0
    pred_coef[key]=$8
    pred_file[key]=$12
    pred_units[sim SUBSEP unit]=1
    all_sims[sim]=1
    all_pairs_seen[sim SUBSEP pair]=1
    next
  }

  ARGIND==3 {
    if (all_pairs != "") {
      if (FNR==1 && ($1 ~ /sample|id|IID|sample1/)) next
      if (NF >= 2) {
        p=pairid($1,$2)
        # all-pairs file is assumed to apply to all sims seen in inputs.
        external_pairs[p]=1
      }
    }
    next
  }

  END {
    print "sim_id","pred_unit_label","pair_id","sample1","sample2","truth_total_cM","pred_total_cM","truth_n_segments","pred_n_segments","truth_related","pred_related","status","cm_error","cm_abs_error","cm_sq_error","truth_coef","pred_coef","truth_source_file","pred_source_file" > pair_out

    # If no pred units are present for a sim, add default pred unit to avoid empty output.
    for (su in pred_units) {
      split(su,a,SUBSEP)
      sim=a[1]; unit=a[2]
      unit_by_sim[sim]=unit_by_sim[sim] SUBSEP unit
    }

    for (sim in all_sims) {
      units_str=unit_by_sim[sim]
      if (units_str == "") units_str=SUBSEP "pred"
      n=split(units_str, units, SUBSEP)
      for (ui=1; ui<=n; ui++) {
        unit=units[ui]
        if (unit=="") continue
        group=sim SUBSEP unit
        groups[group]=1

        # Build evaluation pair universe for this sim/unit.
        delete eval_pair
        for (k in truth_seen) {
          split(k,a,SUBSEP)
          if (a[1]==sim) eval_pair[a[2]]=1
        }
        for (k in pred_seen) {
          split(k,a,SUBSEP)
          if (a[1]==sim && a[2]==unit) eval_pair[a[3]]=1
        }
        if (all_pairs != "") {
          for (p in external_pairs) eval_pair[p]=1
        }

        for (pair in eval_pair) {
          tkey=sim SUBSEP pair
          pkey=sim SUBSEP unit SUBSEP pair

          tcm=(tkey in truth_cm ? truth_cm[tkey] : 0)
          pcm=(pkey in pred_cm ? pred_cm[pkey] : 0)
          tnseg=(tkey in truth_nseg ? truth_nseg[tkey] : 0)
          pnseg=(pkey in pred_nseg ? pred_nseg[pkey] : 0)
          trel=truth_related(tcm)
          prel=pred_related(pcm)

          if (trel==1 && prel==1) status="TP"
          else if (trel==1 && prel==0) status="FN"
          else if (trel==0 && prel==1) status="FP"
          else status="TN"

          split(pair,pp,":")
          s1=pp[1]; s2=pp[2]
          err=pcm-tcm
          abserr=abs(err)
          sqerr=err*err

          tcoef=(tkey in truth_coef ? truth_coef[tkey] : "NA")
          pcoef=(pkey in pred_coef ? pred_coef[pkey] : "NA")
          tf=(tkey in truth_file ? truth_file[tkey] : "NA")
          pf=(pkey in pred_file ? pred_file[pkey] : "NA")

          print sim,unit,pair,s1,s2,tcm,pcm,tnseg,pnseg,trel,prel,status,err,abserr,sqerr,tcoef,pcoef,tf,pf >> pair_out

          total[group]++
          if (status=="TP") TP[group]++
          else if (status=="FP") FP[group]++
          else if (status=="FN") FN[group]++
          else if (status=="TN") TN[group]++

          sum_err[group]+=err
          sum_abs[group]+=abserr
          sum_sq[group]+=sqerr
          if (trel==1) {
            rel_n[group]++
            rel_sum_sq[group]+=sqerr
          }
        }
      }
    }

    print "sim_id","pred_unit_label","n_pairs","TP","FP","FN","TN","precision","recall","FPR","FNR","mean_error_cM","MAE_cM","MSE_cM2","RMSE_cM","related_MSE_cM2","related_RMSE_cM" > group_out

    global_n=global_TP=global_FP=global_FN=global_TN=0
    global_sum_err=global_sum_abs=global_sum_sq=0
    global_rel_n=global_rel_sum_sq=0

    for (g in groups) {
      split(g,a,SUBSEP)
      sim=a[1]; unit=a[2]
      n=total[g]+0
      tp=TP[g]+0; fp=FP[g]+0; fn=FN[g]+0; tn=TN[g]+0
      prec=(tp+fp>0 ? tp/(tp+fp) : "NA")
      rec=(tp+fn>0 ? tp/(tp+fn) : "NA")
      fpr=(fp+tn>0 ? fp/(fp+tn) : "NA")
      fnr=(fn+tp>0 ? fn/(fn+tp) : "NA")
      mean=(n>0 ? sum_err[g]/n : "NA")
      mae=(n>0 ? sum_abs[g]/n : "NA")
      mse=(n>0 ? sum_sq[g]/n : "NA")
      rmse=(n>0 ? sqrt(sum_sq[g]/n) : "NA")
      relmse=(rel_n[g]>0 ? rel_sum_sq[g]/rel_n[g] : "NA")
      relrmse=(rel_n[g]>0 ? sqrt(rel_sum_sq[g]/rel_n[g]) : "NA")

      print sim,unit,n,tp,fp,fn,tn,prec,rec,fpr,fnr,mean,mae,mse,rmse,relmse,relrmse >> group_out

      global_n+=n; global_TP+=tp; global_FP+=fp; global_FN+=fn; global_TN+=tn
      global_sum_err+=sum_err[g]; global_sum_abs+=sum_abs[g]; global_sum_sq+=sum_sq[g]
      global_rel_n+=rel_n[g]; global_rel_sum_sq+=rel_sum_sq[g]
    }

    print "scope","n_pairs","TP","FP","FN","TN","precision","recall","FPR","FNR","mean_error_cM","MAE_cM","MSE_cM2","RMSE_cM","related_MSE_cM2","related_RMSE_cM" > summary_out
    tp=global_TP; fp=global_FP; fn=global_FN; tn=global_TN; n=global_n
    prec=(tp+fp>0 ? tp/(tp+fp) : "NA")
    rec=(tp+fn>0 ? tp/(tp+fn) : "NA")
    fpr=(fp+tn>0 ? fp/(fp+tn) : "NA")
    fnr=(fn+tp>0 ? fn/(fn+tp) : "NA")
    mean=(n>0 ? global_sum_err/n : "NA")
    mae=(n>0 ? global_sum_abs/n : "NA")
    mse=(n>0 ? global_sum_sq/n : "NA")
    rmse=(n>0 ? sqrt(global_sum_sq/n) : "NA")
    relmse=(global_rel_n>0 ? global_rel_sum_sq/global_rel_n : "NA")
    relrmse=(global_rel_n>0 ? sqrt(global_rel_sum_sq/global_rel_n) : "NA")
    print "overall",n,tp,fp,fn,tn,prec,rec,fpr,fnr,mean,mae,mse,rmse,relmse,relrmse >> summary_out
  }
' "$TRUTH_NORM" "$PRED_NORM" ${ALL_PAIRS:+"$ALL_PAIRS"}

info "pair comparison: $PAIR_COMPARE"
info "summary: $SUMMARY"
info "by-group summary: $BY_GROUP"

cat >&2 <<EOF2
========================================
[DONE] Standard IBIS evaluation finished
truth_normalized=$TRUTH_NORM
pred_normalized=$PRED_NORM
merged_long=$MERGED_LONG
pair_compare=$PAIR_COMPARE
summary=$SUMMARY
by_group_summary=$BY_GROUP
========================================
EOF2
