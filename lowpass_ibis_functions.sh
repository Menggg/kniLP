#!/usr/bin/env bash
set -euo pipefail

########################################
# run_make_def_test.sh
#
# Single-file test version for Ped-Sim .def generation.
#
# This script generates Ped-Sim def files and, optionally,
# a text-based family layout / relationship diagram.
# It can also run Ped-Sim as a wrapper when --run-pedsim is used.
#
# Features:
#   1. Parameterized relationship -> def
#   2. Founder number check before def generation
#   3. Custom print-spec support
#   4. Shortcut print modes:
#        --print-all-with-founders
#        --print-all-simulated
#   5. Family layout / arrow-plot text output
#   6. Optional Ped-Sim execution wrapper with all common Ped-Sim CLI options
#   7. Automatic founder matching for Ped-Sim --set_founders
#   8. Automatic chr/no-chr compatibility handling for map/intf vs VCF
#   9. IBIS-only kinship mode for VCF/BCF/PLINK inputs
#   10. One single sh file for easy overwrite
#
# Supported relationships:
#   cousin
#   full_sibling
#   half_sibling
#   grandparent
#   avuncular
#   double_cousin
#   mixed_cousins
#
# Main options:
#   --relationship
#   --degree
#   --half
#   --parent-sex
#   --copies
#   --n-founders
#   --def-name
#   --out-dir
#   --out-def
#   --print-spec
#   --print-all-with-founders
#   --print-all-simulated
#   --plot-family
#   --family-plot-style
#   --family-plot-out
#   --run-pedsim
#   --pedsim-bin
#   --pedsim-map
#   --sort-map / --no-sort-map
#   --sorted-map-out
#   --pedsim-out-prefix
#   --pedsim-vcf
#   --pedsim-intf / --pedsim-pois / --pedsim-fixed-co
#   --founder-id-file
#   --auto-founders-from-vcf / --no-auto-founders-from-vcf
#   --founders-out
#   --founder-random-seed
#   --set-founders-out
#   --founder-map-out
#
# print-spec format:
#   "generation,samples_to_print[,branches[,branch_specs]];generation,samples_to_print..."
#
# Examples:
#   --print-spec "3,1"
#   --print-spec "2,1,2,1n;3,1,1"
#   --print-spec "2,0,2,1:1 2:1;4,1"
#   --print-spec "2,0,2,1sM 2sF;9,1"
########################################


########################################
# 1. Basic helpers
########################################

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

validate_positive_int() {
    local x="$1"
    local name="$2"

    [[ "$x" =~ ^[0-9]+$ && "$x" -ge 1 ]] || {
        die "$name must be a positive integer. Current value: $x"
    }
}

validate_nonnegative_int() {
    local x="$1"
    local name="$2"

    [[ "$x" =~ ^[0-9]+$ ]] || {
        die "$name must be a non-negative integer. Current value: $x"
    }
}

validate_def_name() {
    local name="$1"

    [[ -n "$name" ]] || die "def name is empty"

    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        die "def name contains unsafe characters: $name"
    }
}

normalize_bool01() {
    local x="${1:-0}"

    case "$x" in
        1|true|TRUE|yes|YES|y|Y)
            echo 1
            ;;
        0|false|FALSE|no|NO|n|N|"."|"")
            echo 0
            ;;
        *)
            die "boolean value must be 0/1/true/false/yes/no. Current value: $x"
            ;;
    esac
}

validate_parent_sex() {
    local x="${1:-random}"

    case "$x" in
        random|"."|"")
            echo "random"
            ;;
        M,M|M,F|F,M|F,F)
            echo "$x"
            ;;
        *)
            die "--parent-sex must be random, M,M, M,F, F,M, or F,F. Current value: $x"
            ;;
    esac
}


########################################
# 2. Relationship-level estimates
########################################

estimate_generations_from_relationship() {
    local relationship="$1"
    local degree="${2:-1}"

    case "$relationship" in
        cousin)
            validate_positive_int "$degree" "degree"

            if [[ "$degree" -lt 1 || "$degree" -gt 7 ]]; then
                die "cousin degree currently supports 1..7. Current degree: $degree"
            fi

            echo $((degree + 2))
            ;;

        full_sibling|half_sibling)
            echo 2
            ;;

        grandparent|avuncular|double_cousin)
            echo 3
            ;;

        mixed_cousins)
            echo 4
            ;;

        *)
            die "cannot estimate generations for relationship: $relationship"
            ;;
    esac
}

estimate_founders_per_copy() {
    local relationship="$1"
    local half="${2:-0}"
    local degree="${3:-1}"

    half=$(normalize_bool01 "$half")

    case "$relationship" in
        cousin)
            validate_positive_int "$degree" "degree"

            # Founder genotype positions, not merely the common ancestral couple.
            # Full d-th cousin: common couple + one outside spouse on each branch
            # for each descendant generation before the printed pair => 2 + 2*d.
            # Half d-th cousin: one common founder + two founder spouses in the
            # half-sibling generation + outside spouses on both descendant branches
            # => 3 + 2*d.
            if [[ "$half" == "1" ]]; then
                echo $((2 * degree + 3))
            else
                echo $((2 * degree + 2))
            fi
            ;;

        mixed_cousins)
            # Current built-in mixed_cousins layout has four final branches.
            # Full: common couple + 2 spouses at generation 2 + 4 spouses at generation 3.
            # Half: one common founder + two initial spouses + 2 + 4 descendant spouses.
            if [[ "$half" == "1" ]]; then
                echo 9
            else
                echo 8
            fi
            ;;

        full_sibling)
            echo 2
            ;;

        half_sibling)
            echo 3
            ;;

        grandparent)
            # grandparent + spouse to create parent, plus parent spouse to create grandchild
            echo 3
            ;;

        avuncular)
            # common grandparents plus outside spouse of the parent branch
            echo 3
            ;;

        double_cousin)
            echo 4
            ;;

        *)
            die "cannot estimate founders for relationship: $relationship"
            ;;
    esac
}


########################################
# 3. Founder check
########################################

check_founders_before_def() {
    local relationship="$1"
    local half="$2"
    local copies="$3"
    local n_founders="$4"
    local degree="${5:-1}"

    validate_positive_int "$copies" "copies"
    validate_positive_int "$n_founders" "n_founders"

    local founders_per_copy
    local required_founders
    local missing_founders
    local max_allowed_copies

    founders_per_copy=$(estimate_founders_per_copy "$relationship" "$half" "$degree")
    required_founders=$((founders_per_copy * copies))

    if [[ "$n_founders" -lt "$required_founders" ]]; then
        missing_founders=$((required_founders - n_founders))
    else
        missing_founders=0
    fi

    max_allowed_copies=$((n_founders / founders_per_copy))

    info "founder check before def generation"
    info "relationship=$relationship"
    info "half=$half"
    info "copies=$copies"
    info "founder_positions_per_copy=$founders_per_copy"
    info "required_founders=$required_founders"
    info "available_founders=$n_founders"

    if [[ "$n_founders" -lt "$required_founders" ]]; then
        echo "" >&2
        echo "ERROR: not enough founders to generate this def design." >&2
        echo "relationship       = $relationship" >&2
        echo "half               = $half" >&2
        echo "copies             = $copies" >&2
        echo "founder_positions_per_copy = $founders_per_copy" >&2
        echo "required_founders  = $required_founders" >&2
        echo "available_founders = $n_founders" >&2
        echo "missing_founders   = $missing_founders" >&2
        echo "" >&2
        echo "This design requires at least $required_founders founders." >&2
        echo "You provided $n_founders founders, so you need $missing_founders more founders." >&2
        echo "" >&2
        echo "Options:" >&2
        echo "  1. Increase --n-founders to at least $required_founders" >&2
        echo "  2. Reduce --copies to at most $max_allowed_copies" >&2
        echo "  3. Choose a relationship requiring fewer founders per copy" >&2
        exit 1
    fi
}


########################################
# 4. Default body generators
########################################

make_body_cousin() {
    local degree="$1"
    local half="$2"
    local parent_sex="$3"
    local body_file="$4"

    validate_positive_int "$degree" "degree"

    if [[ "$degree" -lt 1 || "$degree" -gt 7 ]]; then
        die "cousin degree currently supports 1..7. Current degree: $degree"
    fi

    half=$(normalize_bool01 "$half")
    parent_sex=$(validate_parent_sex "$parent_sex")

    local generations
    generations=$((degree + 2))

    : > "$body_file"

    if [[ "$half" == "1" ]]; then
        # Half cousin:
        # Generation 2 has two branches sharing the same i1 parent,
        # but with different founder spouses.
        echo -e "2\t0\t2\t1:1\t2:1" >> "$body_file"
    else
        # Full cousin:
        # Optional parent sex assignment for generation 2 branches.
        if [[ "$parent_sex" != "random" ]]; then
            local sex1
            local sex2
            sex1="${parent_sex%,*}"
            sex2="${parent_sex#*,}"
            echo -e "2\t0\t2\t1s${sex1}\t2s${sex2}" >> "$body_file"
        fi
    fi

    # Default: print one sample per branch in final generation.
    echo -e "${generations}\t1" >> "$body_file"
}

make_body_full_sibling() {
    local body_file="$1"

    cat > "$body_file" <<EOF
2	2	1
EOF
}

make_body_half_sibling() {
    local body_file="$1"

    cat > "$body_file" <<EOF
2	1	2	1:1	2:1
EOF
}

make_body_grandparent() {
    local body_file="$1"

    cat > "$body_file" <<EOF
1	1
2	0	1
3	1
EOF
}

make_body_avuncular() {
    local body_file="$1"

    cat > "$body_file" <<EOF
2	1	2	1n
3	1	1
EOF
}

make_body_double_cousin() {
    local body_file="$1"

    cat > "$body_file" <<EOF
1	0	2
2	0	4
3	1	2	1:1_3	2:2_4
EOF
}

make_body_mixed_cousins() {
    local half="$1"
    local body_file="$2"

    half=$(normalize_bool01 "$half")

    if [[ "$half" == "1" ]]; then
        cat > "$body_file" <<EOF
2	0	2	1:1	2:1
3	0	4
4	1
EOF
    else
        cat > "$body_file" <<EOF
3	0	4
4	1
EOF
    fi
}


########################################
# 5. Print-all body generator
########################################

make_body_print_all_mode() {
    local relationship="$1"
    local degree="$2"
    local half="$3"
    local parent_sex="$4"
    local total_generations="$5"
    local include_founders="$6"
    local body_file="$7"

    half=$(normalize_bool01 "$half")
    parent_sex=$(validate_parent_sex "$parent_sex")

    : > "$body_file"

    local g

    case "$relationship" in
        cousin)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            if [[ "$half" == "1" ]]; then
                # Half cousin structure.
                # Generation 2 has two branches sharing the same founder parent.
                echo -e "2\t1\t2\t1:1\t2:1" >> "$body_file"
            else
                # Full cousin structure.
                if [[ "$parent_sex" != "random" ]]; then
                    local sex1
                    local sex2
                    sex1="${parent_sex%,*}"
                    sex2="${parent_sex#*,}"
                    echo -e "2\t1\t2\t1s${sex1}\t2s${sex2}" >> "$body_file"
                else
                    echo -e "2\t1\t2" >> "$body_file"
                fi
            fi

            if [[ "$total_generations" -ge 3 ]]; then
                for g in $(seq 3 "$total_generations"); do
                    echo -e "${g}\t1\t2" >> "$body_file"
                done
            fi
            ;;

        full_sibling)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            echo -e "2\t2\t1" >> "$body_file"
            ;;

        half_sibling)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            echo -e "2\t1\t2\t1:1\t2:1" >> "$body_file"
            ;;

        grandparent)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            echo -e "2\t1\t1" >> "$body_file"
            echo -e "3\t1\t1" >> "$body_file"
            ;;

        avuncular)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            # Print both generation-2 siblings and the generation-3 descendant.
            echo -e "2\t1\t2" >> "$body_file"
            echo -e "3\t1\t1" >> "$body_file"
            ;;

        double_cousin)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1\t2" >> "$body_file"
            else
                # Still need generation-1 branch structure for double cousin.
                echo -e "1\t0\t2" >> "$body_file"
            fi

            echo -e "2\t1\t4" >> "$body_file"
            echo -e "3\t1\t2\t1:1_3\t2:2_4" >> "$body_file"
            ;;

        mixed_cousins)
            if [[ "$include_founders" == "1" ]]; then
                echo -e "1\t1" >> "$body_file"
            fi

            if [[ "$half" == "1" ]]; then
                echo -e "2\t1\t2\t1:1\t2:1" >> "$body_file"
                echo -e "3\t1\t4" >> "$body_file"
                echo -e "4\t1\t4" >> "$body_file"
            else
                echo -e "2\t1\t2" >> "$body_file"
                echo -e "3\t1\t4" >> "$body_file"
                echo -e "4\t1\t4" >> "$body_file"
            fi
            ;;

        *)
            die "print-all mode not implemented for relationship: $relationship"
            ;;
    esac
}


########################################
# 6. Custom print-spec body generator
########################################

make_body_from_print_spec() {
    local print_spec="$1"
    local total_generations="$2"
    local body_file="$3"

    [[ -n "$print_spec" ]] || die "print_spec is empty"

    : > "$body_file"

    echo "$print_spec" | tr ';' '\n' | awk -v max_gen="$total_generations" '
        BEGIN {
            FS=","
            OFS="\t"
        }

        function trim(x) {
            gsub(/^[ \t]+/, "", x)
            gsub(/[ \t]+$/, "", x)
            return x
        }

        NF < 2 {
            print "ERROR: bad print-spec entry: " $0 > "/dev/stderr"
            exit 1
        }

        {
            gen = trim($1)
            nprint = trim($2)
            branches = ""
            specs = ""

            if (NF >= 3) {
                branches = trim($3)
            }

            if (NF >= 4) {
                specs = trim($4)
                for (i=5; i<=NF; i++) {
                    specs = specs "," trim($i)
                }
            }

            if (gen !~ /^[0-9]+$/ || gen < 1) {
                print "ERROR: bad generation in print-spec: " $0 > "/dev/stderr"
                exit 1
            }

            if (gen > max_gen) {
                print "ERROR: print-spec generation exceeds total generations: " $0 > "/dev/stderr"
                print "total_generations=" max_gen > "/dev/stderr"
                exit 1
            }

            if (nprint !~ /^[0-9]+$/) {
                print "ERROR: bad samples_to_print in print-spec: " $0 > "/dev/stderr"
                exit 1
            }

            if (branches == "" || branches == ".") {
                print gen, nprint
            } else {
                if (branches !~ /^[0-9]+$/) {
                    print "ERROR: bad branch count in print-spec: " $0 > "/dev/stderr"
                    exit 1
                }

                if (specs == "" || specs == ".") {
                    print gen, nprint, branches
                } else {
                    print gen, nprint, branches, specs
                }
            }
        }
    ' > "$body_file"
}


########################################
# 7. Write def
########################################

write_def_file() {
    local def_name="$1"
    local copies="$2"
    local generations="$3"
    local body_file="$4"
    local out_def="$5"

    validate_def_name "$def_name"
    validate_positive_int "$copies" "copies"
    validate_positive_int "$generations" "generations"

    [[ -s "$body_file" ]] || die "body file is empty: $body_file"

    mkdir -p "$(dirname "$out_def")"

    {
        echo "def $def_name $copies $generations"

        awk '
            BEGIN {
                FS="[ \t]+"
                OFS="\t"
            }

            NF == 0 {next}
            $1 ~ /^#/ {next}

            {
                for (i=1; i<=NF; i++) {
                    if (i > 1) printf OFS
                    printf "%s", $i
                }
                printf "\n"
            }
        ' "$body_file"
    } > "$out_def"

    info "def file written: $out_def"
}


########################################
# 8. Basic syntax validation
########################################

validate_def_syntax_basic() {
    local def_file="$1"

    [[ -s "$def_file" ]] || die "def file missing or empty: $def_file"

    awk '
        BEGIN {
            ok=1
            n_def=0
            current_generations=0
        }

        NF == 0 {next}
        $1 ~ /^#/ {next}

        $1 == "def" {
            n_def++

            if (NF < 4 || NF > 5) {
                print "ERROR: bad def line: " $0 > "/dev/stderr"
                ok=0
            }

            if ($3 !~ /^[0-9]+$/ || $3 < 1) {
                print "ERROR: copies must be positive integer: " $0 > "/dev/stderr"
                ok=0
            }

            if ($4 !~ /^[0-9]+$/ || $4 < 1) {
                print "ERROR: generations must be positive integer: " $0 > "/dev/stderr"
                ok=0
            }

            if (NF == 5 && $5 !~ /^[FM]$/) {
                print "ERROR: sex_i1 must be F or M: " $0 > "/dev/stderr"
                ok=0
            }

            current_generations=$4
            next
        }

        {
            if (n_def == 0) {
                print "ERROR: generation line appears before def line: " $0 > "/dev/stderr"
                ok=0
            }

            if ($1 !~ /^[0-9]+$/ || $1 < 1) {
                print "ERROR: generation number must be positive integer: " $0 > "/dev/stderr"
                ok=0
            }

            if ($2 !~ /^[0-9]+$/) {
                print "ERROR: samples_to_print must be non-negative integer: " $0 > "/dev/stderr"
                ok=0
            }

            if (NF >= 3 && $3 !~ /^[0-9]+$/) {
                print "ERROR: branches must be integer if present: " $0 > "/dev/stderr"
                ok=0
            }

            if (current_generations > 0 && $1 > current_generations) {
                print "ERROR: generation line exceeds def generations: " $0 > "/dev/stderr"
                ok=0
            }
        }

        END {
            if (n_def == 0) {
                print "ERROR: no def entry found" > "/dev/stderr"
                ok=0
            }

            if (ok != 1) exit 1
        }
    ' "$def_file"

    info "basic def syntax check passed: $def_file"
}




########################################
# 9. Family visual / relationship path plot
########################################

validate_family_plot_style() {
    local x="${1:-pdf-style}"

    case "$x" in
        layout|pdf-style|pdf-style-compact)
            echo "$x"
            ;;
        *)
            die "--family-plot-style must be layout, pdf-style, or pdf-style-compact. Current value: $x"
            ;;
    esac
}

make_family_visual() {
    local def_file="$1"
    local style="${2:-pdf-style}"
    local out_file="${3:-}"

    [[ -s "$def_file" ]] || die "def file missing or empty for family plot: $def_file"
    style=$(validate_family_plot_style "$style")

    local awk_cmd

    if [[ -n "$out_file" && "$out_file" != "-" ]]; then
        mkdir -p "$(dirname "$out_file")"
        awk_cmd="file"
    else
        awk_cmd="stdout"
    fi

    if [[ "$awk_cmd" == "file" ]]; then
        awk -v STYLE="$style" '
function K(g,b,i) { return g SUBSEP b SUBSEP i }
function KB(g,b) { return g SUBSEP b }
function max(a,b) { return a>b ? a : b }
function min(a,b) { return a<b ? a : b }
function abs(x) { return x < 0 ? -x : x }
function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
function spaces(n,   s,i) { s=""; for (i=1;i<=n;i++) s=s " "; return s }

function split_branch_expr(expr, arr,   n,np,parts,i,part,ab,a,b,j) {
  delete arr
  n=0
  np=split(expr, parts, ",")
  for (i=1; i<=np; i++) {
    part=parts[i]
    if (part == "") continue
    if (part ~ /-/) {
      split(part, ab, "-")
      a=ab[1]+0; b=ab[2]+0
      for (j=a; j<=b; j++) arr[++n]=j
    } else {
      arr[++n]=part+0
    }
  }
  return n
}

function ensure_spouse(g,b,   key) {
  key=KB(g,b)
  if (spouse_count[key] < 1) spouse_count[key]=1
  return 1
}

function set_no_parents(g,b,i,   key) {
  key=K(g,b,i)
  pcnt[key]=0
}

function set_two_parents(cg,cb,ci,p1g,p1b,p1sp,p2g,p2b,p2sp,   key) {
  key=K(cg,cb,ci)
  pcnt[key]=2
  par1g[key]=p1g; par1b[key]=p1b; par1sp[key]=p1sp
  par2g[key]=p2g; par2b[key]=p2b; par2sp[key]=p2sp
}

function label(prefix,g,b,i,sp) {
  if (sp > 0) return prefix "_g" g "-b" b "-s" sp
  return prefix "_g" g "-b" b "-i" i
}

function branch_order(g,b,nb) {
  if (g == 1) return "right"

  if (nb == 2) {
    if (b == 1) return "left"
    if (b == 2) return (g % 2 == 0 ? "right" : "left")
  }

  return (b % 2 == 1 ? "left" : "right")
}

function append_token(s,t) {
  if (t == "") return s
  if (s == "") return t
  return s " " t
}

function branch_text(prefix,g,b,use_arrow,   nb,spc,ord,primary,s1,txt,i,s,extra) {
  nb=nbranch[g]
  spc=spouse_count[KB(g,b)]+0
  ord=branch_order(g,b,nb)
  primary=label(prefix,g,b,1,0)

  extra=0
  if (nprint[g] > 1 && !((g SUBSEP b) in no_print)) extra=nprint[g]-1

  if (use_arrow && spc == 1 && extra == 0) {
    s1=label(prefix,g,b,1,1)
    if (ord == "left") return s1 " <--> " primary
    else return primary " <--> " s1
  }

  txt=""
  if (ord == "left") {
    for (s=1; s<=spc; s++) txt=append_token(txt, label(prefix,g,b,1,s))
    txt=append_token(txt, primary)
  } else {
    txt=append_token(txt, primary)
    for (s=1; s<=spc; s++) txt=append_token(txt, label(prefix,g,b,1,s))
  }

  if (extra > 0) {
    for (i=2; i<=nprint[g]; i++) txt=append_token(txt, label(prefix,g,b,i,0))
  }

  return txt
}

function center_pos(g,b,W,   nb,left,right,usable,step) {
  nb=nbranch[g]

  if (nb == 1) return int(W/2)

  left=5
  right=5
  usable=W-left-right

  if (nb == 2) {
    if (b == 1) return int(left + usable/4)
    else return int(left + 3*usable/4)
  }

  step=usable/(nb-1)
  return int(left + (b-1)*step)
}

function set_char(line,pos,ch,   before,after) {
  if (pos < 1 || pos > length(line)) return line
  before=substr(line,1,pos-1)
  after=substr(line,pos+1)
  return before ch after
}

function draw_h(line,x1,x2,ch,   a,b,i,c) {
  a=min(x1,x2)
  b=max(x1,x2)

  for (i=a; i<=b; i++) {
    c=substr(line,i,1)
    if (c == " ") line=set_char(line,i,ch)
  }

  return line
}

function put_center(row,center,text,W,   start,i,pos) {
  start=center-int(length(text)/2)

  if (start < 1) start=1
  if (start + length(text) - 1 > W) start=W-length(text)+1
  if (start < 1) start=1

  for (i=1; i<=length(text); i++) {
    pos=start+i-1
    if (pos>=1 && pos<=W) row=set_char(row,pos,substr(text,i,1))
  }

  return row
}

function add_conn(p,c) {
  if (!(p in conn_seen)) {
    conn_seen[p]=1
    p_list[++np]=p
  }
  conn_kids[p]=conn_kids[p] " " c
}

function render_connectors(W,   row1,row2,row3,idx,p,nk,tmp,i,c,left,right,nearest) {
  row1=spaces(W)
  row2=spaces(W)
  row3=spaces(W)

  for (idx=1; idx<=np; idx++) {
    p=p_list[idx]
    row1=set_char(row1,p,"|")

    nk=split(conn_kids[p], tmp, " ")
    left=0
    right=0

    for (i=1; i<=nk; i++) {
      c=tmp[i]+0
      if (c <= 0) continue
      if (left == 0 || c < left) left=c
      if (right == 0 || c > right) right=c
    }

    if (left == 0) continue

    if (left == right) {
      c=left

      if (c == p) {
        row2=set_char(row2,p,"|")
      } else {
        row2=draw_h(row2,p,c,"-")
        row2=set_char(row2,p,"+")
        row2=set_char(row2,c,"+")
      }

      row3=set_char(row3,c,"v")

    } else {
      row2=draw_h(row2,left,right,"-")
      row2=set_char(row2,left,"+")
      row2=set_char(row2,right,"+")

      if (p >= left && p <= right) {
        row2=set_char(row2,p,"+")
      } else {
        nearest=(abs(p-left)<abs(p-right)?left:right)
        row2=draw_h(row2,p,nearest,"-")
        row2=set_char(row2,p,"+")
      }

      for (i=1; i<=nk; i++) {
        c=tmp[i]+0
        if (c > 0) {
          row2=set_char(row2,c,"+")
          row3=set_char(row3,c,"v")
        }
      }
    }
  }

  if (rtrim(row1) != "") print rtrim(row1)
  if (rtrim(row2) != "") print rtrim(row2)
  if (rtrim(row3) != "") print rtrim(row3)
}

function build_graph(   g,b,key,curr,prev,n,p,sp,cb,start,end,tokn,toks,tok,pos,lhs,rhs,ncurr,currs,j,p1,p2part,a,p2,pg2,i,expr,nn,tmpbranches) {
  prev=0

  for (g=1; g<=ngen; g++) {
    if (!(g in nbranch)) {
      if (g == 1) nbranch[g]=1
      else if (g == 2) nbranch[g]=2
      else nbranch[g]=prev
    }
    prev=nbranch[g]
  }

  for (g=1; g<=ngen; g++) {
    for (b=1; b<=nbranch[g]; b++) {
      set_no_parents(g,b,1)
    }
  }

  for (g=2; g<=ngen; g++) {
    curr=nbranch[g]
    prev=nbranch[g-1]

    if (curr >= prev) {
      n=int(curr/prev)

      for (p=1; p<=prev; p++) {
        if (n <= 0) continue

        sp=ensure_spouse(g-1,p)
        start=(p-1)*n+1
        end=p*n

        for (cb=start; cb<=end && cb<=curr; cb++) {
          set_two_parents(g,cb,1,g-1,p,0,g-1,p,sp)
        }
      }

    } else {
      for (cb=1; cb<=curr; cb++) {
        sp=ensure_spouse(g-1,cb)
        set_two_parents(g,cb,1,g-1,cb,0,g-1,cb,sp)
      }
    }

    tokn=split(specs[g], toks, " ")

    for (i=1; i<=tokn; i++) {
      tok=toks[i]

      if (tok == "") continue
      if (tok ~ /^[0-9,-]+n$/) continue
      if (tok ~ /^[0-9,-]+s[MF]$/) continue

      pos=index(tok,":")
      if (pos <= 0) continue

      lhs=substr(tok,1,pos-1)
      rhs=substr(tok,pos+1)
      ncurr=split_branch_expr(lhs,currs)

      if (rhs == "") {
        for (j=1; j<=ncurr; j++) set_no_parents(g,currs[j],1)
        continue
      }

      if (index(rhs,"_") == 0) {
        p1=rhs+0
        sp=ensure_spouse(g-1,p1)

        for (j=1; j<=ncurr; j++) {
          set_two_parents(g,currs[j],1,g-1,p1,0,g-1,p1,sp)
        }

      } else {
        split(rhs,a,"_")
        p1=a[1]+0
        p2part=a[2]

        if (index(p2part,"^") > 0) {
          split(p2part,a,"^")
          p2=a[1]+0
          pg2=a[2]+0
        } else {
          p2=p2part+0
          pg2=g-1
        }

        for (j=1; j<=ncurr; j++) {
          set_two_parents(g,currs[j],1,g-1,p1,0,pg2,p2,0)
        }
      }
    }
  }
}

function render_layout(copy,   prefix,g,b,row,txt) {
  prefix=defname copy

  for (g=1; g<=ngen; g++) {
    row=""

    for (b=1; b<=nbranch[g]; b++) {
      txt=branch_text(prefix,g,b,0)

      if (row == "") row=txt
      else row=row "  " txt
    }

    print row
  }
}

function calc_width(copy,use_arrow,   prefix,g,b,txt,maxlen,maxb,W) {
  prefix=defname copy
  maxlen=0
  maxb=0

  for (g=1; g<=ngen; g++) {
    if (nbranch[g] > maxb) maxb=nbranch[g]

    for (b=1; b<=nbranch[g]; b++) {
      txt=branch_text(prefix,g,b,use_arrow)
      if (length(txt) > maxlen) maxlen=length(txt)
    }
  }

  W=max(100, maxb*(maxlen+12))
  return W
}

function render_pdf(copy,use_arrow,   prefix,W,g,b,row,txt,childkey,cb,cg,pcenter,ccenter,cnt,sum) {
  prefix=defname copy
  W=calc_width(copy,use_arrow)

  for (g=1; g<=ngen; g++) {
    row=spaces(W)

    for (b=1; b<=nbranch[g]; b++) {
      txt=branch_text(prefix,g,b,use_arrow)
      row=put_center(row,center_pos(g,b,W),txt,W)
    }

    print rtrim(row)

    if (g < ngen) {
      delete conn_kids
      delete conn_seen
      delete p_list
      np=0

      cg=g+1

      for (cb=1; cb<=nbranch[cg]; cb++) {
        childkey=K(cg,cb,1)

        if (pcnt[childkey] < 1) continue

        cnt=0
        sum=0

        if (par1g[childkey] == g && par1sp[childkey] == 0) {
          sum += center_pos(g,par1b[childkey],W)
          cnt++
        }

        if (par2g[childkey] == g && par2sp[childkey] == 0) {
          sum += center_pos(g,par2b[childkey],W)
          cnt++
        }

        if (cnt > 0) {
          pcenter=int(sum/cnt)
          ccenter=center_pos(cg,cb,W)
          add_conn(pcenter,ccenter)
        }
      }

      render_connectors(W)
    }
  }
}

BEGIN {
  def_seen=0
}

/^[[:space:]]*$/ { next }
/^[[:space:]]*#/ { next }

$1 == "def" {
  if (def_seen) {
    next
  }

  def_seen=1
  defname=$2
  copies=$3+0
  ngen=$4+0
  next
}

def_seen {
  g=$1+0
  nprint[g]=$2+0

  start=3

  if (NF >= 3 && $3 ~ /^[0-9]+$/) {
    nbranch[g]=$3+0
    start=4
  }

  specs[g]=""

  for (i=start; i<=NF; i++) {
    if (specs[g] == "") specs[g]=$i
    else specs[g]=specs[g] " " $i

    if ($i ~ /^[0-9,-]+n$/) {
      expr=substr($i,1,length($i)-1)
      nn=split_branch_expr(expr,tmpbranches)

      for (j=1; j<=nn; j++) {
        no_print[g SUBSEP tmpbranches[j]]=1
      }
    }
  }
}

END {
  if (!def_seen) {
    print "[ERROR] No def block found." > "/dev/stderr"
    exit 1
  }

  build_graph()

  if (copies < 1) copies=1

  for (copy=1; copy<=copies; copy++) {
    if (copy > 1) print ""

    if (STYLE == "layout") {
      render_layout(copy)
    } else if (STYLE == "pdf-style") {
      render_pdf(copy,1)
    } else if (STYLE == "pdf-style-compact") {
      render_pdf(copy,0)
    }
  }
}
' "$def_file" > "$out_file"
        info "family plot written: $out_file"
    else
        awk -v STYLE="$style" '
function K(g,b,i) { return g SUBSEP b SUBSEP i }
function KB(g,b) { return g SUBSEP b }
function max(a,b) { return a>b ? a : b }
function min(a,b) { return a<b ? a : b }
function abs(x) { return x < 0 ? -x : x }
function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
function spaces(n,   s,i) { s=""; for (i=1;i<=n;i++) s=s " "; return s }

function split_branch_expr(expr, arr,   n,np,parts,i,part,ab,a,b,j) {
  delete arr
  n=0
  np=split(expr, parts, ",")
  for (i=1; i<=np; i++) {
    part=parts[i]
    if (part == "") continue
    if (part ~ /-/) {
      split(part, ab, "-")
      a=ab[1]+0; b=ab[2]+0
      for (j=a; j<=b; j++) arr[++n]=j
    } else {
      arr[++n]=part+0
    }
  }
  return n
}

function ensure_spouse(g,b,   key) { key=KB(g,b); if (spouse_count[key] < 1) spouse_count[key]=1; return 1 }
function set_no_parents(g,b,i,   key) { key=K(g,b,i); pcnt[key]=0 }
function set_two_parents(cg,cb,ci,p1g,p1b,p1sp,p2g,p2b,p2sp,   key) { key=K(cg,cb,ci); pcnt[key]=2; par1g[key]=p1g; par1b[key]=p1b; par1sp[key]=p1sp; par2g[key]=p2g; par2b[key]=p2b; par2sp[key]=p2sp }
function label(prefix,g,b,i,sp) { if (sp > 0) return prefix "_g" g "-b" b "-s" sp; return prefix "_g" g "-b" b "-i" i }
function branch_order(g,b,nb) { if (g == 1) return "right"; if (nb == 2) { if (b == 1) return "left"; if (b == 2) return (g % 2 == 0 ? "right" : "left") }; return (b % 2 == 1 ? "left" : "right") }
function append_token(s,t) { if (t == "") return s; if (s == "") return t; return s " " t }
function branch_text(prefix,g,b,use_arrow,   nb,spc,ord,primary,s1,txt,i,s,extra) { nb=nbranch[g]; spc=spouse_count[KB(g,b)]+0; ord=branch_order(g,b,nb); primary=label(prefix,g,b,1,0); extra=0; if (nprint[g] > 1 && !((g SUBSEP b) in no_print)) extra=nprint[g]-1; if (use_arrow && spc == 1 && extra == 0) { s1=label(prefix,g,b,1,1); if (ord == "left") return s1 " <--> " primary; else return primary " <--> " s1 }; txt=""; if (ord == "left") { for (s=1; s<=spc; s++) txt=append_token(txt, label(prefix,g,b,1,s)); txt=append_token(txt, primary) } else { txt=append_token(txt, primary); for (s=1; s<=spc; s++) txt=append_token(txt, label(prefix,g,b,1,s)) }; if (extra > 0) { for (i=2; i<=nprint[g]; i++) txt=append_token(txt, label(prefix,g,b,i,0)) }; return txt }
function center_pos(g,b,W,   nb,left,right,usable,step) { nb=nbranch[g]; if (nb == 1) return int(W/2); left=5; right=5; usable=W-left-right; if (nb == 2) { if (b == 1) return int(left + usable/4); else return int(left + 3*usable/4) }; step=usable/(nb-1); return int(left + (b-1)*step) }
function set_char(line,pos,ch,   before,after) { if (pos < 1 || pos > length(line)) return line; before=substr(line,1,pos-1); after=substr(line,pos+1); return before ch after }
function draw_h(line,x1,x2,ch,   a,b,i,c) { a=min(x1,x2); b=max(x1,x2); for (i=a; i<=b; i++) { c=substr(line,i,1); if (c == " ") line=set_char(line,i,ch) }; return line }
function put_center(row,center,text,W,   start,i,pos) { start=center-int(length(text)/2); if (start < 1) start=1; if (start + length(text) - 1 > W) start=W-length(text)+1; if (start < 1) start=1; for (i=1; i<=length(text); i++) { pos=start+i-1; if (pos>=1 && pos<=W) row=set_char(row,pos,substr(text,i,1)) }; return row }
function add_conn(p,c) { if (!(p in conn_seen)) { conn_seen[p]=1; p_list[++np]=p }; conn_kids[p]=conn_kids[p] " " c }
function render_connectors(W,   row1,row2,row3,idx,p,nk,tmp,i,c,left,right,nearest) { row1=spaces(W); row2=spaces(W); row3=spaces(W); for (idx=1; idx<=np; idx++) { p=p_list[idx]; row1=set_char(row1,p,"|"); nk=split(conn_kids[p], tmp, " "); left=0; right=0; for (i=1; i<=nk; i++) { c=tmp[i]+0; if (c <= 0) continue; if (left == 0 || c < left) left=c; if (right == 0 || c > right) right=c }; if (left == 0) continue; if (left == right) { c=left; if (c == p) { row2=set_char(row2,p,"|") } else { row2=draw_h(row2,p,c,"-"); row2=set_char(row2,p,"+"); row2=set_char(row2,c,"+") }; row3=set_char(row3,c,"v") } else { row2=draw_h(row2,left,right,"-"); row2=set_char(row2,left,"+"); row2=set_char(row2,right,"+"); if (p >= left && p <= right) { row2=set_char(row2,p,"+") } else { nearest=(abs(p-left)<abs(p-right)?left:right); row2=draw_h(row2,p,nearest,"-"); row2=set_char(row2,p,"+") }; for (i=1; i<=nk; i++) { c=tmp[i]+0; if (c > 0) { row2=set_char(row2,c,"+"); row3=set_char(row3,c,"v") } } } }; if (rtrim(row1) != "") print rtrim(row1); if (rtrim(row2) != "") print rtrim(row2); if (rtrim(row3) != "") print rtrim(row3) }
function build_graph(   g,b,key,curr,prev,n,p,sp,cb,start,end,tokn,toks,tok,pos,lhs,rhs,ncurr,currs,j,p1,p2part,a,p2,pg2,i,expr,nn,tmpbranches) { prev=0; for (g=1; g<=ngen; g++) { if (!(g in nbranch)) { if (g == 1) nbranch[g]=1; else if (g == 2) nbranch[g]=2; else nbranch[g]=prev }; prev=nbranch[g] }; for (g=1; g<=ngen; g++) { for (b=1; b<=nbranch[g]; b++) { set_no_parents(g,b,1) } }; for (g=2; g<=ngen; g++) { curr=nbranch[g]; prev=nbranch[g-1]; if (curr >= prev) { n=int(curr/prev); for (p=1; p<=prev; p++) { if (n <= 0) continue; sp=ensure_spouse(g-1,p); start=(p-1)*n+1; end=p*n; for (cb=start; cb<=end && cb<=curr; cb++) { set_two_parents(g,cb,1,g-1,p,0,g-1,p,sp) } } } else { for (cb=1; cb<=curr; cb++) { sp=ensure_spouse(g-1,cb); set_two_parents(g,cb,1,g-1,cb,0,g-1,cb,sp) } }; tokn=split(specs[g], toks, " "); for (i=1; i<=tokn; i++) { tok=toks[i]; if (tok == "") continue; if (tok ~ /^[0-9,-]+n$/) continue; if (tok ~ /^[0-9,-]+s[MF]$/) continue; pos=index(tok,":"); if (pos <= 0) continue; lhs=substr(tok,1,pos-1); rhs=substr(tok,pos+1); ncurr=split_branch_expr(lhs,currs); if (rhs == "") { for (j=1; j<=ncurr; j++) set_no_parents(g,currs[j],1); continue }; if (index(rhs,"_") == 0) { p1=rhs+0; sp=ensure_spouse(g-1,p1); for (j=1; j<=ncurr; j++) { set_two_parents(g,currs[j],1,g-1,p1,0,g-1,p1,sp) } } else { split(rhs,a,"_"); p1=a[1]+0; p2part=a[2]; if (index(p2part,"^") > 0) { split(p2part,a,"^"); p2=a[1]+0; pg2=a[2]+0 } else { p2=p2part+0; pg2=g-1 }; for (j=1; j<=ncurr; j++) { set_two_parents(g,currs[j],1,g-1,p1,0,pg2,p2,0) } } } } }
function render_layout(copy,   prefix,g,b,row,txt) { prefix=defname copy; for (g=1; g<=ngen; g++) { row=""; for (b=1; b<=nbranch[g]; b++) { txt=branch_text(prefix,g,b,0); if (row == "") row=txt; else row=row "  " txt }; print row } }
function calc_width(copy,use_arrow,   prefix,g,b,txt,maxlen,maxb,W) { prefix=defname copy; maxlen=0; maxb=0; for (g=1; g<=ngen; g++) { if (nbranch[g] > maxb) maxb=nbranch[g]; for (b=1; b<=nbranch[g]; b++) { txt=branch_text(prefix,g,b,use_arrow); if (length(txt) > maxlen) maxlen=length(txt) } }; W=max(100, maxb*(maxlen+12)); return W }
function render_pdf(copy,use_arrow,   prefix,W,g,b,row,txt,childkey,cb,cg,pcenter,ccenter,cnt,sum) { prefix=defname copy; W=calc_width(copy,use_arrow); for (g=1; g<=ngen; g++) { row=spaces(W); for (b=1; b<=nbranch[g]; b++) { txt=branch_text(prefix,g,b,use_arrow); row=put_center(row,center_pos(g,b,W),txt,W) }; print rtrim(row); if (g < ngen) { delete conn_kids; delete conn_seen; delete p_list; np=0; cg=g+1; for (cb=1; cb<=nbranch[cg]; cb++) { childkey=K(cg,cb,1); if (pcnt[childkey] < 1) continue; cnt=0; sum=0; if (par1g[childkey] == g && par1sp[childkey] == 0) { sum += center_pos(g,par1b[childkey],W); cnt++ }; if (par2g[childkey] == g && par2sp[childkey] == 0) { sum += center_pos(g,par2b[childkey],W); cnt++ }; if (cnt > 0) { pcenter=int(sum/cnt); ccenter=center_pos(cg,cb,W); add_conn(pcenter,ccenter) } }; render_connectors(W) } } }
BEGIN { def_seen=0 }
/^[[:space:]]*$/ { next }
/^[[:space:]]*#/ { next }
$1 == "def" { if (def_seen) { next }; def_seen=1; defname=$2; copies=$3+0; ngen=$4+0; next }
def_seen { g=$1+0; nprint[g]=$2+0; start=3; if (NF >= 3 && $3 ~ /^[0-9]+$/) { nbranch[g]=$3+0; start=4 }; specs[g]=""; for (i=start; i<=NF; i++) { if (specs[g] == "") specs[g]=$i; else specs[g]=specs[g] " " $i; if ($i ~ /^[0-9,-]+n$/) { expr=substr($i,1,length($i)-1); nn=split_branch_expr(expr,tmpbranches); for (j=1; j<=nn; j++) { no_print[g SUBSEP tmpbranches[j]]=1 } } } }
END { if (!def_seen) { print "[ERROR] No def block found." > "/dev/stderr"; exit 1 }; build_graph(); if (copies < 1) copies=1; for (copy=1; copy<=copies; copy++) { if (copy > 1) print ""; if (STYLE == "layout") { render_layout(copy) } else if (STYLE == "pdf-style") { render_pdf(copy,1) } else if (STYLE == "pdf-style-compact") { render_pdf(copy,0) } } }
' "$def_file"
    fi
}


########################################
# 10. Founder matching for Ped-Sim --set_founders
########################################

validate_founder_map_mode() {
    local x="${1:-repeat}"

    case "$x" in
        repeat|sequential)
            echo "$x"
            ;;
        *)
            die "--founder-map-mode must be repeat or sequential. Current value: $x"
            ;;
    esac
}

make_pedsim_founder_position_list() {
    local def_file="$1"
    local out_file="$2"

    [[ -s "$def_file" ]] || die "def file missing or empty for founder matching: $def_file"
    mkdir -p "$(dirname "$out_file")"

    awk '
function K(g,b,i) { return g SUBSEP b SUBSEP i }
function KB(g,b) { return g SUBSEP b }

function split_branch_expr(expr, arr,   n,np,parts,i,part,ab,a,b,j) {
    delete arr
    n=0
    np=split(expr, parts, ",")
    for (i=1; i<=np; i++) {
        part=parts[i]
        if (part == "") continue
        if (part ~ /-/) {
            split(part, ab, "-")
            a=ab[1]+0
            b=ab[2]+0
            for (j=a; j<=b; j++) arr[++n]=j
        } else {
            arr[++n]=part+0
        }
    }
    return n
}

function new_spouse(g,b,   key) {
    key=KB(g,b)
    spouse_count[key]++
    return spouse_count[key]
}

function set_no_parents(g,b,i,   key) {
    key=K(g,b,i)
    pcnt[key]=0
}

function set_two_parents(cg,cb,ci,p1g,p1b,p1sp,p2g,p2b,p2sp,   key) {
    key=K(cg,cb,ci)
    pcnt[key]=2
    par1g[key]=p1g; par1b[key]=p1b; par1sp[key]=p1sp
    par2g[key]=p2g; par2b[key]=p2b; par2sp[key]=p2sp
}

function label(prefix,g,b,i,sp) {
    if (sp > 0) return prefix "_g" g "-b" b "-s" sp
    return prefix "_g" g "-b" b "-i" i
}

function build_graph(   g,b,curr,prev,n,p,sp,cb,start,end,tokn,toks,tok,pos,lhs,rhs,ncurr,currs,j,p1,p2part,a,p2,pg2) {
    prev=0

    for (g=1; g<=ngen; g++) {
        if (!(g in nbranch)) {
            if (g == 1) nbranch[g]=1
            else if (g == 2) nbranch[g]=2
            else nbranch[g]=prev
        }
        prev=nbranch[g]
    }

    for (g=1; g<=ngen; g++) {
        for (b=1; b<=nbranch[g]; b++) {
            set_no_parents(g,b,1)
        }
    }

    for (g=2; g<=ngen; g++) {
        curr=nbranch[g]
        prev=nbranch[g-1]

        # Default Ped-Sim branching rule.
        # When one parent branch splits into multiple child branches, those child
        # branches are siblings and share the same outside spouse founder.
        if (curr >= prev) {
            n=int(curr/prev)

            for (p=1; p<=prev; p++) {
                if (n <= 0) continue

                sp=new_spouse(g-1,p)
                start=(p-1)*n+1
                end=p*n

                for (cb=start; cb<=end && cb<=curr; cb++) {
                    set_two_parents(g,cb,1,g-1,p,0,g-1,p,sp)
                }
            }
        } else {
            for (cb=1; cb<=curr; cb++) {
                sp=new_spouse(g-1,cb)
                set_two_parents(g,cb,1,g-1,cb,0,g-1,cb,sp)
            }
        }

        # Explicit branch specifications override the default. For single-parent
        # specifications such as 1:1 2:1, each token receives a new spouse. This
        # is what allows half-sib / half-cousin structures to use different
        # outside founders while sharing one pedigree parent.
        tokn=split(specs[g], toks, " ")

        for (i=1; i<=tokn; i++) {
            tok=toks[i]

            if (tok == "") continue
            if (tok ~ /^[0-9,-]+n$/) continue
            if (tok ~ /^[0-9,-]+s[MF]$/) continue

            pos=index(tok,":")
            if (pos <= 0) continue

            lhs=substr(tok,1,pos-1)
            rhs=substr(tok,pos+1)
            ncurr=split_branch_expr(lhs,currs)

            if (rhs == "") {
                for (j=1; j<=ncurr; j++) set_no_parents(g,currs[j],1)
                continue
            }

            if (index(rhs,"_") == 0) {
                p1=rhs+0
                sp=new_spouse(g-1,p1)

                for (j=1; j<=ncurr; j++) {
                    set_two_parents(g,currs[j],1,g-1,p1,0,g-1,p1,sp)
                }
            } else {
                split(rhs,a,"_")
                p1=a[1]+0
                p2part=a[2]

                if (index(p2part,"^") > 0) {
                    split(p2part,a,"^")
                    p2=a[1]+0
                    pg2=a[2]+0
                } else {
                    p2=p2part+0
                    pg2=g-1
                }

                for (j=1; j<=ncurr; j++) {
                    set_two_parents(g,currs[j],1,g-1,p1,0,pg2,p2,0)
                }
            }
        }
    }
}

BEGIN { def_seen=0 }
/^[[:space:]]*$/ { next }
/^[[:space:]]*#/ { next }

$1 == "def" {
    if (def_seen) next
    def_seen=1
    defname=$2
    copies=$3+0
    ngen=$4+0
    next
}

def_seen {
    g=$1+0
    start=3
    if (NF >= 3 && $3 ~ /^[0-9]+$/) {
        nbranch[g]=$3+0
        start=4
    }

    specs[g]=""
    for (i=start; i<=NF; i++) {
        if (specs[g] == "") specs[g]=$i
        else specs[g]=specs[g] " " $i
    }
}

END {
    if (!def_seen) {
        print "ERROR: no def block found" > "/dev/stderr"
        exit 1
    }

    build_graph()

    # Only spouse nodes that are actually used as parents are true founder
    # genotype sources. This avoids listing default spouses that were later
    # overwritten by explicit branch specs such as 1:1 2:1.
    for (key in pcnt) {
        if (pcnt[key] != 2) continue
        if (par1sp[key] > 0) used_spouse[par1g[key] SUBSEP par1b[key] SUBSEP par1sp[key]]=1
        if (par2sp[key] > 0) used_spouse[par2g[key] SUBSEP par2b[key] SUBSEP par2sp[key]]=1
    }

    # Compress spouse numbering after overrides. For example, if an unused
    # default s1 was overwritten and the real spouses were temporarily s2/s3,
    # the Ped-Sim-facing IDs should be s1/s2.
    for (g=1; g<=ngen; g++) {
        for (b=1; b<=nbranch[g]; b++) {
            n_used=0
            for (s=1; s<=spouse_count[KB(g,b)]; s++) {
                oldkey=g SUBSEP b SUBSEP s
                if (oldkey in used_spouse) {
                    n_used++
                    spouse_renum[oldkey]=n_used
                    used_spouse_count[KB(g,b)]=n_used
                }
            }
        }
    }

    if (copies < 1) copies=1

    for (copy=1; copy<=copies; copy++) {
        prefix=defname copy
        idx=0

        for (g=1; g<=ngen; g++) {
            for (b=1; b<=nbranch[g]; b++) {
                key=K(g,b,1)

                if (pcnt[key] == 0) {
                    idx++
                    print copy, idx, label(prefix,g,b,1,0), "primary_founder"
                }

                for (s=1; s<=spouse_count[KB(g,b)]; s++) {
                    oldkey=g SUBSEP b SUBSEP s
                    if (!(oldkey in used_spouse)) continue
                    idx++
                    print copy, idx, label(prefix,g,b,1,spouse_renum[oldkey]), "spouse_founder"
                }
            }
        }
    }
}
' OFS='\t' "$def_file" > "$out_file"

    [[ -s "$out_file" ]] || die "no founder positions were detected from def: $def_file"
}


extract_vcf_sample_ids() {
    local vcf_file="$1"
    local out_file="$2"

    [[ -s "$vcf_file" ]] || die "VCF file missing or empty: $vcf_file"
    mkdir -p "$(dirname "$out_file")"

    if command -v bcftools >/dev/null 2>&1; then
        bcftools query -l "$vcf_file" > "$out_file"
    else
        case "$vcf_file" in
            *.bcf)
                die "cannot read BCF sample IDs without bcftools: $vcf_file"
                ;;
            *.gz|*.bgz)
                gzip -cd "$vcf_file" | awk '
                    /^#CHROM[ \t]/ {
                        for (i=10; i<=NF; i++) print $i
                        found=1
                        exit
                    }
                    END { if (!found) exit 1 }
                ' > "$out_file" || die "failed to parse VCF header sample IDs: $vcf_file"
                ;;
            *)
                awk '
                    /^#CHROM[ \t]/ {
                        for (i=10; i<=NF; i++) print $i
                        found=1
                        exit
                    }
                    END { if (!found) exit 1 }
                ' "$vcf_file" > "$out_file" || die "failed to parse VCF header sample IDs: $vcf_file"
                ;;
        esac
    fi

    [[ -s "$out_file" ]] || die "no sample IDs found in VCF: $vcf_file"
}

count_vcf_sample_ids() {
    local vcf_file="$1"
    local tmp_ids
    tmp_ids=$(mktemp)
    extract_vcf_sample_ids "$vcf_file" "$tmp_ids"
    wc -l < "$tmp_ids" | awk '{print $1}'
    rm -f "$tmp_ids"
}

required_founder_id_count_from_def() {
    local def_file="$1"
    local mode="${2:-repeat}"
    local tmp_positions
    tmp_positions=$(mktemp)

    mode=$(validate_founder_map_mode "$mode")
    make_pedsim_founder_position_list "$def_file" "$tmp_positions"

    awk -v mode="$mode" '
        BEGIN { FS=OFS="\t" }
        {
            n_pos++
            copy=$1 + 0
            idx=$2 + 0
            if (copy > n_copy) n_copy=copy
            if (idx > per_copy[copy]) per_copy[copy]=idx
        }
        END {
            if (n_pos < 1) {
                print "ERROR: no founder positions detected" > "/dev/stderr"
                exit 1
            }
            max_per_copy=0
            for (c=1; c<=n_copy; c++) {
                if (per_copy[c] > max_per_copy) max_per_copy=per_copy[c]
            }
            if (mode == "repeat") print max_per_copy
            else if (mode == "sequential") print n_pos
            else {
                print "ERROR: unknown founder map mode: " mode > "/dev/stderr"
                exit 1
            }
        }
    ' "$tmp_positions"

    rm -f "$tmp_positions"
}

select_random_founder_ids_from_vcf() {
    local vcf_file="$1"
    local def_file="$2"
    local founders_out="$3"
    local mode="${4:-repeat}"
    local seed="${5:-}"

    [[ -s "$vcf_file" ]] || die "VCF file missing or empty for automatic founder selection: $vcf_file"
    [[ -s "$def_file" ]] || die "def file missing or empty for automatic founder selection: $def_file"
    mode=$(validate_founder_map_mode "$mode")

    if [[ -n "$seed" ]]; then
        validate_nonnegative_int "$seed" "founder random seed"
    fi

    mkdir -p "$(dirname "$founders_out")"

    local tmp_all_ids
    local n_needed
    local n_available
    tmp_all_ids=$(mktemp)

    extract_vcf_sample_ids "$vcf_file" "$tmp_all_ids"
    n_needed=$(required_founder_id_count_from_def "$def_file" "$mode")
    n_available=$(wc -l < "$tmp_all_ids" | awk '{print $1}')

    if [[ "$n_available" -lt "$n_needed" ]]; then
        rm -f "$tmp_all_ids"
        die "not enough VCF sample IDs for founder selection: need $n_needed, available $n_available in $vcf_file"
    fi

    # Random sample without replacement. If --founder-random-seed is supplied,
    # the same VCF/sample list and same def design produce the same founders.txt.
    if [[ -n "$seed" ]]; then
        awk -v seed="$seed" 'BEGIN{srand(seed)} NF>0 {printf "%.17f\t%s\n", rand(), $0}' "$tmp_all_ids" \
            | LC_ALL=C sort -k1,1n \
            | awk -v n="$n_needed" 'BEGIN{FS="\t"} NR<=n {print $2}' \
            > "$founders_out"
    else
        awk 'BEGIN{srand()} NF>0 {printf "%.17f\t%s\n", rand(), $0}' "$tmp_all_ids" \
            | LC_ALL=C sort -k1,1n \
            | awk -v n="$n_needed" 'BEGIN{FS="\t"} NR<=n {print $2}' \
            > "$founders_out"
    fi

    rm -f "$tmp_all_ids"

    [[ -s "$founders_out" ]] || die "failed to create founders.txt from VCF: $founders_out"

    info "random founders selected from VCF: $founders_out"
    info "founder IDs selected=$n_needed"
    info "VCF sample IDs available=$n_available"
}

write_pedsim_set_founders_from_id_file() {
    local def_file="$1"
    local founder_id_file="$2"
    local set_founders_out="$3"
    local annotated_map_out="$4"
    local mode="${5:-repeat}"

    [[ -s "$def_file" ]] || die "def file missing or empty for --set_founders generation: $def_file"
    [[ -s "$founder_id_file" ]] || die "founder ID file missing or empty: $founder_id_file"
    mode=$(validate_founder_map_mode "$mode")

    mkdir -p "$(dirname "$set_founders_out")"
    if [[ -n "$annotated_map_out" && "$annotated_map_out" != "-" ]]; then
        mkdir -p "$(dirname "$annotated_map_out")"
    fi

    local tmp_positions
    local tmp_ids
    tmp_positions=$(mktemp)
    tmp_ids=$(mktemp)

    make_pedsim_founder_position_list "$def_file" "$tmp_positions"

    awk '
        NF == 0 {next}
        $1 ~ /^#/ {next}
        {print $1}
    ' "$founder_id_file" > "$tmp_ids"

    [[ -s "$tmp_ids" ]] || die "founder ID file has no usable sample IDs: $founder_id_file"

    awk \
        -v mode="$mode" \
        -v set_out="$set_founders_out" \
        -v map_out="$annotated_map_out" '
        BEGIN {
            FS=OFS="\t"
        }

        FNR == NR {
            ids[++n_ids]=$1
            next
        }

        {
            n_pos++
            copy[n_pos]=$1
            idx[n_pos]=$2
            ped[n_pos]=$3
            role[n_pos]=$4
            if ($1 > n_copy) n_copy=$1
            if ($2 > per_copy[$1]) per_copy[$1]=$2
        }

        END {
            if (n_ids < 1) {
                print "ERROR: no founder IDs loaded" > "/dev/stderr"
                exit 1
            }
            if (n_pos < 1) {
                print "ERROR: no Ped-Sim founder positions loaded" > "/dev/stderr"
                exit 1
            }

            max_per_copy=0
            for (c=1; c<=n_copy; c++) {
                if (per_copy[c] > max_per_copy) max_per_copy=per_copy[c]
            }

            if (mode == "repeat") {
                if (n_ids < max_per_copy) {
                    print "ERROR: not enough founder IDs for repeat mode" > "/dev/stderr"
                    print "founder IDs provided = " n_ids > "/dev/stderr"
                    print "founder positions per copy required = " max_per_copy > "/dev/stderr"
                    exit 1
                }
            } else if (mode == "sequential") {
                if (n_ids < n_pos) {
                    print "ERROR: not enough founder IDs for sequential mode" > "/dev/stderr"
                    print "founder IDs provided = " n_ids > "/dev/stderr"
                    print "total founder positions required = " n_pos > "/dev/stderr"
                    exit 1
                }
            } else {
                print "ERROR: unknown founder map mode: " mode > "/dev/stderr"
                exit 1
            }

            if (map_out != "" && map_out != "-") {
                print "copy", "founder_index_in_copy", "global_mapping_index", "genotype_sample_id", "ped_sim_founder_id", "founder_role" > map_out
            }

            for (i=1; i<=n_pos; i++) {
                if (mode == "repeat") {
                    sid=ids[idx[i]]
                } else {
                    sid=ids[i]
                }

                print ped[i], sid > set_out

                if (map_out != "" && map_out != "-") {
                    print copy[i], idx[i], i, sid, ped[i], role[i] > map_out
                }
            }
        }
    ' "$tmp_ids" "$tmp_positions"

    rm -f "$tmp_positions" "$tmp_ids"

    info "Ped-Sim --set_founders file written: $set_founders_out"
    if [[ -n "$annotated_map_out" && "$annotated_map_out" != "-" ]]; then
        info "annotated founder map written: $annotated_map_out"
    fi
}



########################################
# 11. Map sorting / checking helpers
########################################

validate_map_sort_mode() {
    local x="${1:-1}"
    normalize_bool01 "$x"
}

map_check_sorted() {
    local map_file="$1"
    local label="${2:-map}"

    [[ -s "$map_file" ]] || die "$label file missing or empty: $map_file"

    awk -v label="$label" '
        BEGIN {
            prev_chr = ""
            prev_pos = -1
            bad = 0
        }

        NF == 0 { next }
        /^#/ { next }

        {
            chr = $1
            pos = $2 + 0

            if (chr == prev_chr && pos < prev_pos) {
                print "ERROR: " label " column 2 is not sorted within chromosome" > "/dev/stderr"
                print "file: " FILENAME > "/dev/stderr"
                print "line: " NR > "/dev/stderr"
                print "prev: " prev_chr " " prev_pos > "/dev/stderr"
                print "curr: " chr " " pos > "/dev/stderr"
                bad = 1
                exit 1
            }

            prev_chr = chr
            prev_pos = pos
        }

        END {
            if (bad == 0) {
                print "[INFO] " label " position sorting check passed: " FILENAME > "/dev/stderr"
            }
        }
    ' "$map_file"
}

write_vcf_chrom_order_file() {
    local vcf="$1"
    local out_file="$2"

    : > "$out_file"

    if [[ -z "$vcf" || ! -s "$vcf" ]]; then
        return 0
    fi

    if command -v bcftools >/dev/null 2>&1; then
        bcftools index -s "$vcf" 2>/dev/null | cut -f1 > "$out_file" || true

        if [[ ! -s "$out_file" ]]; then
            bcftools view -h "$vcf" 2>/dev/null \
                | awk '
                    /^##contig=/{
                        x=$0
                        sub(/^.*ID=/, "", x)
                        sub(/[,>].*$/, "", x)
                        if (x != "") print x
                    }
                ' > "$out_file" || true
        fi
    fi

    if [[ ! -s "$out_file" ]]; then
        if [[ "$vcf" =~ \.gz$ ]]; then
            gzip -dc "$vcf" 2>/dev/null \
                | awk '
                    /^##contig=/{
                        x=$0
                        sub(/^.*ID=/, "", x)
                        sub(/[,>].*$/, "", x)
                        if (x != "") print x
                    }
                    /^#CHROM/{exit}
                ' > "$out_file" || true
        else
            awk '
                /^##contig=/{
                    x=$0
                    sub(/^.*ID=/, "", x)
                    sub(/[,>].*$/, "", x)
                    if (x != "") print x
                }
                /^#CHROM/{exit}
            ' "$vcf" > "$out_file" || true
        fi
    fi
}


validate_chrom_fix_mode() {
    local x="${1:-1}"

    case "$x" in
        1|true|TRUE|yes|YES|y|Y)
            echo 1
            ;;
        0|false|FALSE|no|NO|n|N)
            echo 0
            ;;
        *)
            die "chromosome ID fix mode must be 0/1/true/false/yes/no. Current value: $x"
            ;;
    esac
}

make_chrom_compat_out_path() {
    local in_file="$1"
    local suffix="$2"

    local base
    base=$(basename "$in_file")

    case "$base" in
        *.simmap)
            echo "${OUTPUT_DIR}/${base%.simmap}.${suffix}.simmap"
            ;;
        *.tsv)
            echo "${OUTPUT_DIR}/${base%.tsv}.${suffix}.tsv"
            ;;
        *.txt)
            echo "${OUTPUT_DIR}/${base%.txt}.${suffix}.txt"
            ;;
        *)
            echo "${OUTPUT_DIR}/${base}.${suffix}"
            ;;
    esac
}

write_pedsim_data_chrom_order_file() {
    local in_file="$1"
    local out_file="$2"

    [[ -s "$in_file" ]] || die "input file missing or empty for chromosome order: $in_file"

    awk '
        function isnum(x) {
            return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
        }
        NF == 0 {next}
        /^#/ {next}
        !isnum($2) {next}
        !seen[$1]++ {print $1}
    ' "$in_file" > "$out_file"
}

normalize_chrom_ids_to_vcf() {
    local in_file="$1"
    local out_file="$2"
    local vcf="$3"
    local label="$4"

    [[ -s "$in_file" ]] || die "$label file missing or empty: $in_file"
    [[ -s "$vcf" ]] || die "VCF file missing or empty for chromosome ID compatibility check: $vcf"

    mkdir -p "$(dirname "$out_file")"

    local chr_order
    chr_order=$(mktemp)
    write_vcf_chrom_order_file "$vcf" "$chr_order"

    if [[ ! -s "$chr_order" ]]; then
        rm -f "$chr_order"
        die "could not read chromosome IDs from VCF: $vcf"
    fi

    local tmp_out
    tmp_out=$(mktemp)

    awk -v label="$label" '
        BEGIN {
            OFS="\t"
            changed=0
            bad=0
            n_bad=0
        }

        NR == FNR {
            ord[$1]=FNR
            next
        }

        function isnum(x) {
            return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
        }

        function strip_chr(x, y) {
            y=x
            sub(/^chr/, "", y)
            sub(/^CHR/, "", y)
            return y
        }

        function map_chr(c, s, cc) {
            if (c in ord) return c

            s=strip_chr(c)
            if (s in ord) return s

            cc="chr" s
            if (cc in ord) return cc

            cc="CHR" s
            if (cc in ord) return cc

            if (s == "M" && ("MT" in ord)) return "MT"
            if (s == "MT" && ("M" in ord)) return "M"
            if (s == "M" && ("chrM" in ord)) return "chrM"
            if (s == "MT" && ("chrMT" in ord)) return "chrMT"
            if (s == "M" && ("chrMT" in ord)) return "chrMT"
            if (s == "MT" && ("chrM" in ord)) return "chrM"

            return ""
        }

        NF == 0 {
            print $0
            next
        }

        /^#/ {
            print $0
            next
        }

        !isnum($2) {
            # Header line such as: chr nu_0 p_0 nu_1 p_1
            print $0
            next
        }

        {
            old=$1
            new=map_chr(old)
            if (new == "") {
                if (!(old in bad_chr)) {
                    bad_chr[old]=1
                    bad_list[++n_bad]=old
                }
                bad=1
                next
            }

            if (new != old) changed=1
            $1=new
            print
        }

        END {
            if (bad) {
                print "ERROR: " label " contains chromosome IDs not found in VCF, even after chr/no-chr conversion:" > "/dev/stderr"
                for (i=1; i<=n_bad; i++) print "  " bad_list[i] > "/dev/stderr"
                exit 1
            }
            if (changed) {
                print "[INFO] " label " chromosome IDs were converted to match VCF IDs" > "/dev/stderr"
            } else {
                print "[INFO] " label " chromosome IDs already match VCF IDs" > "/dev/stderr"
            }
        }
    ' "$chr_order" "$in_file" > "$tmp_out"

    mv "$tmp_out" "$out_file"
    rm -f "$chr_order"
    info "$label VCF-compatible file written: $out_file"
}

check_chrom_ids_exact_subset_of_vcf() {
    local in_file="$1"
    local vcf="$2"
    local label="$3"

    [[ -s "$in_file" ]] || die "$label file missing or empty: $in_file"
    [[ -s "$vcf" ]] || return 0

    local chr_order
    chr_order=$(mktemp)
    write_vcf_chrom_order_file "$vcf" "$chr_order"

    if [[ ! -s "$chr_order" ]]; then
        rm -f "$chr_order"
        return 0
    fi

    awk -v label="$label" '
        NR == FNR {
            ok[$1]=1
            next
        }
        function isnum(x) {
            return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
        }
        NF == 0 || /^#/ || !isnum($2) {next}
        !($1 in ok) && !seen[$1]++ {
            bad[++n_bad]=$1
        }
        END {
            if (n_bad > 0) {
                print "ERROR: " label " chromosome IDs are not compatible with VCF IDs:" > "/dev/stderr"
                for (i=1; i<=n_bad; i++) print "  " bad[i] > "/dev/stderr"
                print "Use --fix-chrom-ids, or manually make chr naming consistent." > "/dev/stderr"
                exit 1
            }
        }
    ' "$chr_order" "$in_file"

    rm -f "$chr_order"
}

sort_intf_file_by_order_file() {
    local in_intf="$1"
    local out_intf="$2"
    local order_file="$3"
    local label="${4:-Ped-Sim interference file}"

    [[ -s "$in_intf" ]] || die "$label missing or empty: $in_intf"
    [[ -s "$order_file" ]] || die "chromosome order file missing or empty for $label: $order_file"
    mkdir -p "$(dirname "$out_intf")"

    local tmp_out
    tmp_out=$(mktemp)

    {
        awk '
            function isnum(x) {
                return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
            }
            NF == 0 {print; next}
            /^#/ {print; next}
            !isnum($2) {print; next}
        ' "$in_intf"

        awk '
            BEGIN {OFS="\t"}
            NR == FNR {
                ord[$1]=FNR
                next
            }
            function isnum(x) {
                return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
            }
            NF == 0 || /^#/ || !isnum($2) {next}
            {
                o = (($1 in ord) ? ord[$1] : 999999999)
                print o, $0
            }
        ' "$order_file" "$in_intf" \
            | LC_ALL=C sort -k1,1n -k2,2V \
            | cut -f2-
    } > "$tmp_out"

    mv "$tmp_out" "$out_intf"
    info "$label sorted/reordered file written: $out_intf"
}

check_intf_matches_map_chrom_order() {
    local map_file="$1"
    local intf_file="$2"

    [[ -s "$map_file" ]] || die "map file missing or empty for compatibility check: $map_file"
    [[ -s "$intf_file" ]] || die "interference file missing or empty for compatibility check: $intf_file"

    local map_order intf_order
    map_order=$(mktemp)
    intf_order=$(mktemp)

    write_pedsim_data_chrom_order_file "$map_file" "$map_order"
    write_pedsim_data_chrom_order_file "$intf_file" "$intf_order"

    if ! diff -q "$map_order" "$intf_order" >/dev/null 2>&1; then
        echo "ERROR: Ped-Sim genetic map and interference file chromosome IDs/order are not identical after preparation." >&2
        echo "Map chromosome order:" >&2
        sed 's/^/  /' "$map_order" >&2
        echo "Interference chromosome order:" >&2
        sed 's/^/  /' "$intf_order" >&2
        rm -f "$map_order" "$intf_order"
        exit 1
    fi

    rm -f "$map_order" "$intf_order"
    info "Ped-Sim genetic map and interference file chromosome IDs/order are compatible"
}

prepare_pedsim_chrom_ids() {
    if [[ -z "$PEDSIM_VCF" ]]; then
        return 0
    fi

    [[ -s "$PEDSIM_VCF" ]] || die "Ped-Sim input VCF missing or empty: $PEDSIM_VCF"

    if [[ "$PEDSIM_FIX_CHROM_IDS" == "1" ]]; then
        if [[ -n "$PEDSIM_MAP" ]]; then
            if [[ -z "$PEDSIM_CHROM_FIXED_MAP_OUT" ]]; then
                PEDSIM_CHROM_FIXED_MAP_OUT=$(make_chrom_compat_out_path "$PEDSIM_MAP" "vcfchr")
            fi
            normalize_chrom_ids_to_vcf "$PEDSIM_MAP" "$PEDSIM_CHROM_FIXED_MAP_OUT" "$PEDSIM_VCF" "Ped-Sim genetic map"
            PEDSIM_MAP="$PEDSIM_CHROM_FIXED_MAP_OUT"
        fi

        if [[ -n "$PEDSIM_INTF" ]]; then
            if [[ -z "$PEDSIM_CHROM_FIXED_INTF_OUT" ]]; then
                PEDSIM_CHROM_FIXED_INTF_OUT=$(make_chrom_compat_out_path "$PEDSIM_INTF" "vcfchr")
            fi
            normalize_chrom_ids_to_vcf "$PEDSIM_INTF" "$PEDSIM_CHROM_FIXED_INTF_OUT" "$PEDSIM_VCF" "Ped-Sim interference file"
            PEDSIM_INTF="$PEDSIM_CHROM_FIXED_INTF_OUT"
        fi
    else
        [[ -n "$PEDSIM_MAP" ]] && check_chrom_ids_exact_subset_of_vcf "$PEDSIM_MAP" "$PEDSIM_VCF" "Ped-Sim genetic map"
        [[ -n "$PEDSIM_INTF" ]] && check_chrom_ids_exact_subset_of_vcf "$PEDSIM_INTF" "$PEDSIM_VCF" "Ped-Sim interference file"
    fi
}

prepare_pedsim_intf_order() {
    if [[ -z "$PEDSIM_INTF" ]]; then
        return 0
    fi

    [[ -s "$PEDSIM_INTF" ]] || die "Ped-Sim interference file missing or empty: $PEDSIM_INTF"
    [[ -s "$PEDSIM_MAP" ]] || die "Ped-Sim map must exist before preparing interference file"

    local map_order
    map_order=$(mktemp)
    write_pedsim_data_chrom_order_file "$PEDSIM_MAP" "$map_order"

    if [[ ! -s "$map_order" ]]; then
        rm -f "$map_order"
        die "could not infer chromosome order from Ped-Sim map: $PEDSIM_MAP"
    fi

    if [[ -z "$PEDSIM_SORTED_INTF_OUT" ]]; then
        PEDSIM_SORTED_INTF_OUT=$(make_chrom_compat_out_path "$PEDSIM_INTF" "sorted")
    fi

    sort_intf_file_by_order_file "$PEDSIM_INTF" "$PEDSIM_SORTED_INTF_OUT" "$map_order" "Ped-Sim interference file"
    PEDSIM_INTF="$PEDSIM_SORTED_INTF_OUT"
    rm -f "$map_order"

    check_intf_matches_map_chrom_order "$PEDSIM_MAP" "$PEDSIM_INTF"
}

sort_map_file_for_pedsim() {
    local in_map="$1"
    local out_map="$2"
    local vcf="${3:-}"

    [[ -s "$in_map" ]] || die "map file missing or empty: $in_map"
    mkdir -p "$(dirname "$out_map")"

    local tmp_out
    tmp_out=$(mktemp)

    local chr_order
    chr_order=$(mktemp)

    write_vcf_chrom_order_file "$vcf" "$chr_order"

    if [[ -s "$chr_order" ]]; then
        info "sorting map by VCF chromosome order and physical position"
        {
            awk '/^#/ {print}' "$in_map"
            awk '
                NR==FNR {
                    ord[$1]=NR
                    next
                }
                /^#/ {next}
                NF==0 {next}
                {
                    o = (($1 in ord) ? ord[$1] : 999999999)
                    print o "\t" $0
                }
            ' "$chr_order" "$in_map" \
                | LC_ALL=C sort -k1,1n -k2,2V -k3,3n \
                | cut -f2-
        } > "$tmp_out"
    else
        info "VCF chromosome order was not available; sorting map by chromosome name and physical position"
        {
            awk '/^#/ {print}' "$in_map"
            awk '!/^#/ && NF>0 {print}' "$in_map" \
                | LC_ALL=C sort -k1,1V -k2,2n
        } > "$tmp_out"
    fi

    mv "$tmp_out" "$out_map"
    rm -f "$chr_order"

    map_check_sorted "$out_map" "sorted Ped-Sim map"
    info "sorted map written: $out_map"
}

prepare_pedsim_map() {
    [[ -n "$PEDSIM_MAP" ]] || die "--pedsim-map is required when --run-pedsim is used"
    [[ -s "$PEDSIM_MAP" ]] || die "Ped-Sim map file missing or empty: $PEDSIM_MAP"

    if [[ "$PEDSIM_SORT_MAP" == "1" ]]; then
        if [[ -z "$PEDSIM_SORTED_MAP_OUT" ]]; then
            local map_base
            map_base=$(basename "$PEDSIM_MAP")
            if [[ "$map_base" == *.simmap ]]; then
                PEDSIM_SORTED_MAP_OUT="${OUTPUT_DIR}/${map_base%.simmap}.sorted.simmap"
            else
                PEDSIM_SORTED_MAP_OUT="${OUTPUT_DIR}/${map_base}.sorted"
            fi
        fi

        sort_map_file_for_pedsim "$PEDSIM_MAP" "$PEDSIM_SORTED_MAP_OUT" "$PEDSIM_VCF"
        PEDSIM_MAP="$PEDSIM_SORTED_MAP_OUT"
    else
        map_check_sorted "$PEDSIM_MAP" "Ped-Sim map"
    fi
}


########################################
# 11. Founder VCF preparation / Beagle phasing helpers
########################################

validate_phase_bool01() {
    normalize_bool01 "${1:-0}"
}

validate_phase_impute_mode() {
    local x="${1:-false}"

    case "$x" in
        1|true|TRUE|yes|YES|y|Y)
            echo "true"
            ;;
        0|false|FALSE|no|NO|n|N|""|".")
            echo "false"
            ;;
        *)
            die "--phase-impute must be true/false or 1/0. Current value: $x"
            ;;
    esac
}

strip_chr_prefix() {
    local x="$1"
    x="${x#chr}"
    x="${x#CHR}"
    echo "$x"
}

expand_chrom_list() {
    local spec="$1"
    [[ -n "$spec" ]] || die "--phase-chr is empty"

    echo "$spec" | tr ',' '\n' | awk '
        function stripchr(x) {
            sub(/^chr/, "", x)
            sub(/^CHR/, "", x)
            return x
        }
        NF == 0 {next}
        {
            x=$1
            gsub(/^[ \t]+|[ \t]+$/, "", x)
            if (x == "") next

            if (x ~ /-/) {
                split(x, a, "-")
                s=stripchr(a[1])
                e=stripchr(a[2])
                if (s ~ /^[0-9]+$/ && e ~ /^[0-9]+$/ && s <= e) {
                    for (i=s; i<=e; i++) print i
                } else {
                    print x
                }
            } else {
                print x
            }
        }
    '
}

resolve_vcf_chr_id() {
    local vcf="$1"
    local requested_chr="$2"

    [[ -s "$vcf" ]] || die "VCF file missing or empty: $vcf"

    local chr_order
    chr_order=$(mktemp)
    write_vcf_chrom_order_file "$vcf" "$chr_order"

    if [[ ! -s "$chr_order" ]]; then
        rm -f "$chr_order"
        die "could not read chromosome IDs from VCF: $vcf"
    fi

    local base
    base=$(strip_chr_prefix "$requested_chr")

    local found
    found=$(awk -v req="$requested_chr" -v base="$base" '
        function stripchr(x) {
            sub(/^chr/, "", x)
            sub(/^CHR/, "", x)
            return x
        }
        $1 == req {print $1; exit}
        stripchr($1) == base {print $1; exit}
    ' "$chr_order")

    rm -f "$chr_order"

    [[ -n "$found" ]] || die "requested chromosome $requested_chr was not found in VCF: $vcf"
    echo "$found"
}

replace_chr_template() {
    local template="$1"
    local base_chr="$2"
    local vcf_chr="$3"

    local out="$template"
    out="${out//\{chr\}/$base_chr}"
    out="${out//\{CHR\}/$base_chr}"
    out="${out//\{vcf_chr\}/$vcf_chr}"
    out="${out//\{VCF_CHR\}/$vcf_chr}"
    echo "$out"
}

normalize_position_marker_list_for_chr() {
    local marker_list="$1"
    local out_list="$2"
    local base_chr="$3"
    local vcf_chr="$4"

    [[ -s "$marker_list" ]] || die "marker list missing or empty: $marker_list"
    mkdir -p "$(dirname "$out_list")"

    awk -v base="$base_chr" -v chrom="$vcf_chr" '
        function stripchr(x) {
            sub(/^chr/, "", x)
            sub(/^CHR/, "", x)
            return x
        }
        NF == 0 {next}
        /^#/ {next}
        {
            id=$1
            if (id ~ /:/) {
                split(id, a, ":")
                c=a[1]
                p=a[2]
                if (stripchr(c) == stripchr(base) && p != "") {
                    print chrom ":" p
                }
            } else {
                print id
            }
        }
    ' "$marker_list" | awk '!seen[$0]++' > "$out_list"

    [[ -s "$out_list" ]] || die "no markers remained after normalizing marker list for chromosome $vcf_chr"
}

rewrite_bim_to_chrpos_ids() {
    local bim_file="$1"
    local out_bim="$2"
    local vcf_chr="$3"

    [[ -s "$bim_file" ]] || die "PLINK bim file missing or empty: $bim_file"

    awk -v chrom="$vcf_chr" 'BEGIN{OFS="\t"} NF>=6 {print chrom, chrom":"$4, $3, $4, $5, $6}' "$bim_file" > "$out_bim"
    [[ -s "$out_bim" ]] || die "failed to rewrite bim file: $out_bim"
}

normalize_single_chr_vcf_body() {
    local in_vcf="$1"
    local out_vcf="$2"
    local vcf_chr="$3"

    [[ -s "$in_vcf" ]] || die "VCF file missing or empty: $in_vcf"
    mkdir -p "$(dirname "$out_vcf")"

    awk -v chrom="$vcf_chr" '
        BEGIN {OFS="\t"}
        /^##contig=<ID=/ {
            sub(/ID=[^,>]+/, "ID=" chrom)
            print
            next
        }
        /^#/ {print; next}
        NF > 0 {$1=chrom; print; next}
    ' "$in_vcf" > "$out_vcf"

    [[ -s "$out_vcf" ]] || die "failed to write chromosome-normalized VCF: $out_vcf"
}

check_beagle_map_for_chr() {
    local map_file="$1"
    local vcf_chr="$2"
    local label="${3:-Beagle map}"

    [[ -s "$map_file" ]] || die "$label file missing or empty: $map_file"

    awk -v chrom="$vcf_chr" -v label="$label" '
        BEGIN {
            ok = 1
            found = 0
            prev_pos = -1
            data_rows = 0
        }
        function isnum(x) {
            return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
        }
        NF == 0 {next}
        /^#/ {next}
        {
            # PLINK map format commonly used by Beagle:
            #   CHR  ID  cM  POS
            # Some users also pass a 3-column map-like file:
            #   CHR  POS  cM
            data_rows++
            if ($1 == chrom) found = 1

            pos = ""
            if (NF >= 4 && isnum($3) && isnum($4)) {
                pos = $4 + 0
            } else if (NF >= 3 && isnum($2) && isnum($3)) {
                pos = $2 + 0
            }

            if ($1 == chrom && pos != "") {
                if (prev_pos >= 0 && pos < prev_pos) {
                    print "ERROR: " label " position is not sorted for chromosome " chrom > "/dev/stderr"
                    print "line=" NR ", prev_pos=" prev_pos ", curr_pos=" pos > "/dev/stderr"
                    ok = 0
                    exit 1
                }
                prev_pos = pos
            }
        }
        END {
            if (data_rows == 0) {
                print "ERROR: " label " has no data rows: " FILENAME > "/dev/stderr"
                ok = 0
            }
            if (!found) {
                print "ERROR: " label " does not contain chromosome ID required by target VCF: " chrom > "/dev/stderr"
                ok = 0
            }
            if (ok != 1) exit 1
        }
    ' "$map_file" || {
        echo "[DEBUG] First non-header rows from $map_file:" >&2
        awk 'NF>0 && $1 !~ /^#/ {print; c++; if (c>=5) exit}' "$map_file" >&2
        return 1
    }

    info "$label chromosome check passed for $vcf_chr: $map_file"
}

prepare_beagle_map_for_chr() {
    local in_map="$1"
    local out_map="$2"
    local vcf_chr="$3"

    [[ -s "$in_map" ]] || die "Beagle map file missing or empty: $in_map"
    mkdir -p "$(dirname "$out_map")"

    # Beagle uses the CHROM field in the target/reference VCF to look up entries
    # in the genetic map. The input map may use either 1/2/... or chr1/chr2/...
    # and may be in PLINK 4-column format (CHR ID cM POS) or a simple 3-column
    # map-like format (CHR POS cM). Normalize the chromosome column to the exact
    # VCF chromosome ID and filter to the requested chromosome when possible.
    awk -v chrom="$vcf_chr" '
        BEGIN {OFS="\t"; n=0}
        function stripchr(x) {
            sub(/^chr/, "", x)
            sub(/^CHR/, "", x)
            return x
        }
        NF == 0 {next}
        /^#/ {print; next}
        {
            raw_chr = $1
            # Skip obvious header rows such as: CHR ID cM POS
            if (tolower(raw_chr) ~ /^(chr|chrom|chromosome)$/) next

            # If the map contains multiple chromosomes, keep only the requested one.
            # If it is already a single-chromosome map, this also keeps all valid rows.
            if (stripchr(raw_chr) != stripchr(chrom)) next

            $1 = chrom
            print
            n++
        }
        END {
            if (n == 0) {
                print "ERROR: no rows matching chromosome " chrom " were found in Beagle map " FILENAME > "/dev/stderr"
                exit 1
            }
        }
    ' "$in_map" > "$out_map"

    [[ -s "$out_map" ]] || die "failed to write Beagle map: $out_map"

    # Sort by physical position. For PLINK map, physical position is column 4.
    # For 3-column map-like files, physical position is column 2.
    local sorted_tmp
    sorted_tmp=$(mktemp)
    awk '
        BEGIN {OFS="\t"}
        function isnum(x) {
            return x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
        }
        /^#/ {print "A", NR, $0; next}
        NF >= 4 && isnum($3) && isnum($4) {print "D", $4+0, $0; next}
        NF >= 3 && isnum($2) && isnum($3) {print "D", $2+0, $0; next}
        {print "D", NR, $0}
    ' "$out_map" \
      | LC_ALL=C sort -k1,1 -k2,2n \
      | cut -f3- > "$sorted_tmp"
    mv "$sorted_tmp" "$out_map"

    check_beagle_map_for_chr "$out_map" "$vcf_chr" "Beagle map"
}

prepare_one_phased_founder_vcf_chr() {
    local chr_req="$1"

    local input_vcf="${PHASE_INPUT_VCF:-$PEDSIM_VCF}"
    [[ -s "$input_vcf" ]] || die "--phase-input-vcf is required, or provide --pedsim-vcf"
    [[ -n "$PHASE_PLINK2" ]] || die "--phase-plink2 is empty"
    [[ -n "$PHASE_BEAGLE_JAR" ]] || die "--phase-beagle-jar is required"
    [[ -n "$PHASE_REF_TEMPLATE" ]] || die "--phase-ref-template is required"
    [[ -n "$PHASE_MAP_TEMPLATE" ]] || die "--phase-map-template is required"

    if ! command -v "$PHASE_PLINK2" >/dev/null 2>&1 && [[ ! -x "$PHASE_PLINK2" ]]; then
        die "plink2 executable not found: $PHASE_PLINK2"
    fi

    [[ -s "$PHASE_BEAGLE_JAR" ]] || die "Beagle jar missing or empty: $PHASE_BEAGLE_JAR"

    local vcf_chr base_chr chr_tag chr_out_dir work_dir
    vcf_chr=$(resolve_vcf_chr_id "$input_vcf" "$chr_req")
    base_chr=$(strip_chr_prefix "$vcf_chr")
    chr_tag="chr${base_chr}"

    chr_out_dir="${PHASE_OUT_DIR}/${chr_tag}"
    work_dir="${PHASE_WORK_DIR}/${chr_tag}"
    mkdir -p "$chr_out_dir" "$work_dir"

    local raw_vcf raw_prefix bim_orig marker_compat extracted_prefix exported_vcf target_vcf beagle_map ref_vcf out_prefix
    raw_vcf="${work_dir}/${chr_tag}_highPass.raw.vcf.gz"
    raw_prefix="${work_dir}/${chr_tag}_highPass"
    marker_compat="${work_dir}/${chr_tag}.markers.compat.list"
    extracted_prefix="${work_dir}/${chr_tag}_highPass.gsa"
    exported_vcf="${extracted_prefix}.vcf"
    target_vcf="${chr_out_dir}/${chr_tag}_highPass.beagle_input.vcf"
    beagle_map="${chr_out_dir}/plink.${chr_tag}.GRCh38.beagle.map"
    ref_vcf=$(replace_chr_template "$PHASE_REF_TEMPLATE" "$base_chr" "$vcf_chr")

    if [[ -z "$PHASE_OUT_PREFIX_TEMPLATE" ]]; then
        out_prefix="${chr_out_dir}/phased_${chr_tag}_highPass"
    else
        out_prefix=$(replace_chr_template "$PHASE_OUT_PREFIX_TEMPLATE" "$base_chr" "$vcf_chr")
    fi

    [[ -s "$ref_vcf" ]] || die "Beagle reference VCF missing or empty for chromosome $vcf_chr: $ref_vcf"

    local raw_map
    raw_map=$(replace_chr_template "$PHASE_MAP_TEMPLATE" "$base_chr" "$vcf_chr")
    [[ -s "$raw_map" ]] || die "Beagle map template resolved to missing file for chromosome $vcf_chr: $raw_map"

    echo "========================================"
    echo "[PHASE] Preparing/phasing founder VCF for requested chromosome: $chr_req"
    echo "[PHASE] VCF chromosome ID: $vcf_chr"
    echo "[PHASE] input_vcf=$input_vcf"
    echo "[PHASE] ref_vcf=$ref_vcf"
    echo "[PHASE] raw_map=$raw_map"
    echo "[PHASE] out_prefix=$out_prefix"
    echo "========================================"

    bcftools view -r "$vcf_chr" "$input_vcf" -Oz -o "$raw_vcf"
    bcftools index -f "$raw_vcf"

    "$PHASE_PLINK2" --vcf "$raw_vcf" --make-bed --out "$raw_prefix" --max-alleles 2

    bim_orig="${raw_prefix}.bim.orig"
    cp "${raw_prefix}.bim" "$bim_orig"
    rewrite_bim_to_chrpos_ids "$bim_orig" "${raw_prefix}.bim" "$vcf_chr"

    if [[ -n "$PHASE_MARKER_LIST" ]]; then
        normalize_position_marker_list_for_chr "$PHASE_MARKER_LIST" "$marker_compat" "$base_chr" "$vcf_chr"
        "$PHASE_PLINK2" --bfile "$raw_prefix" --extract "$marker_compat" --export vcf --out "$extracted_prefix"
    else
        info "--phase-marker-list was not provided; exporting all biallelic markers on $vcf_chr"
        "$PHASE_PLINK2" --bfile "$raw_prefix" --export vcf --out "$extracted_prefix"
    fi

    normalize_single_chr_vcf_body "$exported_vcf" "$target_vcf" "$vcf_chr"
    prepare_beagle_map_for_chr "$raw_map" "$beagle_map" "$vcf_chr"

    local -a beagle_cmd
    beagle_cmd=(java -Xmx"$PHASE_XMX" -jar "$PHASE_BEAGLE_JAR" ref="$ref_vcf" map="$beagle_map" impute="$PHASE_IMPUTE" gt="$target_vcf" out="$out_prefix")

    echo "========================================"
    echo "[BEAGLE] Command:"
    print_cmd_shell_quoted "${beagle_cmd[@]}"
    echo "========================================"

    "${beagle_cmd[@]}"

    if [[ -s "${out_prefix}.vcf.gz" ]]; then
        bcftools index -f "${out_prefix}.vcf.gz"
        echo "${out_prefix}.vcf.gz" >> "$PHASE_OUTPUT_LIST"
        info "phased VCF written: ${out_prefix}.vcf.gz"
    else
        die "Beagle output VCF was not found: ${out_prefix}.vcf.gz"
    fi

    if [[ "$PHASE_KEEP_TEMP" != "1" ]]; then
        rm -f "${raw_prefix}.bed" "${raw_prefix}.bim" "${raw_prefix}.fam" "${raw_prefix}.log" "${raw_prefix}.nosex" \
              "${raw_prefix}.bim.orig" "$raw_vcf" "${raw_vcf}.csi" "${raw_vcf}.tbi" \
              "${extracted_prefix}.vcf" "${extracted_prefix}.log" "${extracted_prefix}.nosex" "$marker_compat"
    fi
}

prepare_phased_founder_vcfs() {
    [[ "$PREPARE_FOUNDER_VCF" == "1" ]] || return 0
    [[ -n "$PHASE_CHR" ]] || die "--phase-chr is required with --prepare-founder-vcf/--phase-founders"

    mkdir -p "$PHASE_OUT_DIR" "$PHASE_WORK_DIR"
    PHASE_OUTPUT_LIST="${PHASE_OUT_DIR}/phased_founder_vcf.list"
    : > "$PHASE_OUTPUT_LIST"

    local chr
    while read -r chr; do
        [[ -n "$chr" ]] || continue
        prepare_one_phased_founder_vcf_chr "$chr"
    done < <(expand_chrom_list "$PHASE_CHR")

    info "phased founder VCF list written: $PHASE_OUTPUT_LIST"

    local n_out
    n_out=$(wc -l < "$PHASE_OUTPUT_LIST" | awk '{print $1}')

    if [[ "$PHASE_USE_FOR_PEDSIM" == "1" ]]; then
        if [[ "$n_out" -ne 1 ]]; then
            die "--phase-use-for-pedsim requires exactly one phased VCF output; got $n_out. Merge chromosomes first or run one chromosome only."
        fi
        PEDSIM_VCF=$(cat "$PHASE_OUTPUT_LIST")
        info "using phased founder VCF as Ped-Sim input VCF: $PEDSIM_VCF"
    fi
}

########################################
# 11. Ped-Sim execution wrapper
########################################

validate_existing_file_if_set() {
    local x="$1"
    local name="$2"

    if [[ -n "$x" && ! -s "$x" ]]; then
        die "$name file missing or empty: $x"
    fi
}

validate_float_0_1_if_set() {
    local x="$1"
    local name="$2"

    if [[ -z "$x" ]]; then
        return 0
    fi

    awk -v x="$x" -v name="$name" '
        BEGIN {
            if (x !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/) {
                print "ERROR: " name " must be numeric between 0 and 1. Current value: " x > "/dev/stderr"
                exit 1
            }
            if (x < 0 || x > 1) {
                print "ERROR: " name " must be between 0 and 1. Current value: " x > "/dev/stderr"
                exit 1
            }
        }
    '
}

print_cmd_shell_quoted() {
    local -a cmd=("$@")
    local x
    for x in "${cmd[@]}"; do
        printf '%q ' "$x"
    done
    printf '
'
}

validate_pedsim_options() {
    [[ -n "$PEDSIM_BIN" ]] || die "--pedsim-bin is empty"

    if ! command -v "$PEDSIM_BIN" >/dev/null 2>&1 && [[ ! -x "$PEDSIM_BIN" ]]; then
        die "Ped-Sim executable not found or not executable: $PEDSIM_BIN"
    fi

    [[ -n "$PEDSIM_MAP" ]] || die "--pedsim-map is required when --run-pedsim is used"
    [[ -n "$PEDSIM_OUT_PREFIX" ]] || die "--pedsim-out-prefix is empty"

    validate_existing_file_if_set "$PEDSIM_MAP" "Ped-Sim map"
    validate_existing_file_if_set "$PEDSIM_VCF" "Ped-Sim input VCF"
    validate_existing_file_if_set "$PEDSIM_INTF" "Ped-Sim interference"
    validate_existing_file_if_set "$PEDSIM_FIXED_CO" "Ped-Sim fixed crossover"
    validate_existing_file_if_set "$PEDSIM_SEXES" "Ped-Sim sexes"
    validate_existing_file_if_set "$PEDSIM_SET_FOUNDERS" "Ped-Sim set_founders"

    local n_model=0
    [[ -n "$PEDSIM_INTF" ]] && n_model=$((n_model + 1))
    [[ "$PEDSIM_POIS" == "1" ]] && n_model=$((n_model + 1))
    [[ -n "$PEDSIM_FIXED_CO" ]] && n_model=$((n_model + 1))

    if [[ "$n_model" -ne 1 ]]; then
        die "Ped-Sim requires exactly one crossover model: --pedsim-intf, --pedsim-pois, or --pedsim-fixed-co"
    fi

    if [[ -n "$PEDSIM_SEED" ]]; then
        validate_nonnegative_int "$PEDSIM_SEED" "pedsim seed"
    fi

    validate_float_0_1_if_set "$PEDSIM_ERR_RATE" "--pedsim-err-rate"
    validate_float_0_1_if_set "$PEDSIM_ERR_HOM_RATE" "--pedsim-err-hom-rate"
    validate_float_0_1_if_set "$PEDSIM_MISS_RATE" "--pedsim-miss-rate"
    validate_float_0_1_if_set "$PEDSIM_PSEUDO_HAP" "--pedsim-pseudo-hap"

    if [[ -n "$PEDSIM_MISS_RATE" && -n "$PEDSIM_PSEUDO_HAP" ]]; then
        awk -v m="$PEDSIM_MISS_RATE" -v p="$PEDSIM_PSEUDO_HAP" '
            BEGIN {
                if (m > 0 && p > 0) {
                    print "ERROR: Ped-Sim allows --miss_rate or --pseudo_hap, not both when both are >0" > "/dev/stderr"
                    exit 1
                }
            }
        '
    fi

    if [[ -n "$PEDSIM_RETAIN_EXTRA" ]]; then
        [[ "$PEDSIM_RETAIN_EXTRA" =~ ^-?[0-9]+$ ]] || die "--pedsim-retain-extra must be an integer"
    fi

    mkdir -p "$(dirname "$PEDSIM_OUT_PREFIX")"
}

run_pedsim_from_def() {
    local def_file="$1"

    [[ -s "$def_file" ]] || die "def file missing or empty for Ped-Sim run: $def_file"

    if [[ -z "$PEDSIM_OUT_PREFIX" ]]; then
        PEDSIM_OUT_PREFIX="${def_file%.def}.pedsim"
    fi

    prepare_pedsim_chrom_ids
    prepare_pedsim_map
    prepare_pedsim_intf_order
    validate_pedsim_options

    local -a cmd
    cmd=("$PEDSIM_BIN" -d "$def_file" -m "$PEDSIM_MAP" -o "$PEDSIM_OUT_PREFIX")

    [[ -n "$PEDSIM_VCF" ]] && cmd+=(-i "$PEDSIM_VCF")
    [[ -n "$PEDSIM_CHR_X" ]] && cmd+=(-X "$PEDSIM_CHR_X")
    [[ -n "$PEDSIM_INTF" ]] && cmd+=(--intf "$PEDSIM_INTF")
    [[ "$PEDSIM_POIS" == "1" ]] && cmd+=(--pois)
    [[ -n "$PEDSIM_FIXED_CO" ]] && cmd+=(--fixed_co "$PEDSIM_FIXED_CO")
    [[ -n "$PEDSIM_SEED" ]] && cmd+=(--seed "$PEDSIM_SEED")
    [[ -n "$PEDSIM_SEXES" ]] && cmd+=(--sexes "$PEDSIM_SEXES")
    [[ "$PEDSIM_DRY_RUN" == "1" ]] && cmd+=(--dry_run)
    [[ "$PEDSIM_FAM" == "1" ]] && cmd+=(--fam)
    [[ "$PEDSIM_BP" == "1" ]] && cmd+=(--bp)
    [[ "$PEDSIM_MRCA" == "1" ]] && cmd+=(--mrca)
    [[ "$PEDSIM_NOGZ" == "1" ]] && cmd+=(--nogz)
    [[ "$PEDSIM_KEEP_PHASE" == "1" ]] && cmd+=(--keep_phase)
    [[ "$PEDSIM_FOUNDER_IDS" == "1" ]] && cmd+=(--founder_ids)
    [[ -n "$PEDSIM_SET_FOUNDERS" ]] && cmd+=(--set_founders "$PEDSIM_SET_FOUNDERS")
    [[ -n "$PEDSIM_RETAIN_EXTRA" ]] && cmd+=(--retain_extra "$PEDSIM_RETAIN_EXTRA")
    [[ -n "$PEDSIM_ERR_RATE" ]] && cmd+=(--err_rate "$PEDSIM_ERR_RATE")
    [[ -n "$PEDSIM_ERR_HOM_RATE" ]] && cmd+=(--err_hom_rate "$PEDSIM_ERR_HOM_RATE")
    [[ -n "$PEDSIM_MISS_RATE" ]] && cmd+=(--miss_rate "$PEDSIM_MISS_RATE")
    [[ -n "$PEDSIM_PSEUDO_HAP" ]] && cmd+=(--pseudo_hap "$PEDSIM_PSEUDO_HAP")

    if [[ "${#PEDSIM_EXTRA_ARGS[@]}" -gt 0 ]]; then
        cmd+=("${PEDSIM_EXTRA_ARGS[@]}")
    fi

    echo "========================================"
    echo "[PEDSIM] Command:"
    print_cmd_shell_quoted "${cmd[@]}"
    echo "========================================"

    if [[ "$PEDSIM_PRINT_CMD_ONLY" == "1" ]]; then
        info "--pedsim-print-cmd-only was set; command was not executed"
        return 0
    fi

    "${cmd[@]}"

    echo "========================================"
    echo "[DONE] Ped-Sim run finished"
    echo "PEDSIM_OUT_PREFIX=$PEDSIM_OUT_PREFIX"
    echo "========================================"

    for f in         "${PEDSIM_OUT_PREFIX}.log"         "${PEDSIM_OUT_PREFIX}.seg"         "${PEDSIM_OUT_PREFIX}.vcf"         "${PEDSIM_OUT_PREFIX}.vcf.gz"         "${PEDSIM_OUT_PREFIX}.bp"         "${PEDSIM_OUT_PREFIX}.mrca"         "${PEDSIM_OUT_PREFIX}.ids"         "${PEDSIM_OUT_PREFIX}-everyone.fam"; do
        if [[ -e "$f" ]]; then
            echo "$f"
        fi
    done
}


########################################
# 12. Main def generation API
########################################

make_def_from_relationship() {
    local relationship="$1"
    local degree="$2"
    local half="$3"
    local copies="$4"
    local n_founders="$5"
    local def_name="$6"
    local out_def="$7"
    local parent_sex="${8:-random}"
    local print_spec="${9:-}"
    local print_all_with_founders="${10:-0}"
    local print_all_simulated="${11:-0}"

    half=$(normalize_bool01 "$half")
    print_all_with_founders=$(normalize_bool01 "$print_all_with_founders")
    print_all_simulated=$(normalize_bool01 "$print_all_simulated")

    if [[ "$print_all_with_founders" == "1" && "$print_all_simulated" == "1" ]]; then
        die "cannot use --print-all-with-founders and --print-all-simulated at the same time"
    fi

    check_founders_before_def \
        "$relationship" \
        "$half" \
        "$copies" \
        "$n_founders" \
        "$degree"

    local body_file
    local generations

    generations=$(estimate_generations_from_relationship "$relationship" "$degree")
    body_file=$(mktemp)

    if [[ -n "$print_spec" && "$print_spec" != "." && "$print_spec" != "auto" ]]; then
        info "using custom print-spec: $print_spec"

        make_body_from_print_spec \
            "$print_spec" \
            "$generations" \
            "$body_file"

    elif [[ "$print_all_with_founders" == "1" ]]; then
        info "using print-all-with-founders mode"

        make_body_print_all_mode \
            "$relationship" \
            "$degree" \
            "$half" \
            "$parent_sex" \
            "$generations" \
            "1" \
            "$body_file"

    elif [[ "$print_all_simulated" == "1" ]]; then
        info "using print-all-simulated mode"

        make_body_print_all_mode \
            "$relationship" \
            "$degree" \
            "$half" \
            "$parent_sex" \
            "$generations" \
            "0" \
            "$body_file"

    else
        case "$relationship" in
            cousin)
                make_body_cousin "$degree" "$half" "$parent_sex" "$body_file"
                ;;

            full_sibling)
                make_body_full_sibling "$body_file"
                ;;

            half_sibling)
                make_body_half_sibling "$body_file"
                ;;

            grandparent)
                make_body_grandparent "$body_file"
                ;;

            avuncular)
                make_body_avuncular "$body_file"
                ;;

            double_cousin)
                make_body_double_cousin "$body_file"
                ;;

            mixed_cousins)
                make_body_mixed_cousins "$half" "$body_file"
                ;;

            *)
                rm -f "$body_file"
                die "unsupported relationship: $relationship"
                ;;
        esac
    fi

    write_def_file \
        "$def_name" \
        "$copies" \
        "$generations" \
        "$body_file" \
        "$out_def"

    rm -f "$body_file"

    validate_def_syntax_basic "$out_def"
}



########################################
# 12. IBIS-only kinship module
########################################

ibis_check_file() {
    local f="$1"
    [[ -s "$f" ]] || die "missing or empty file: $f"
}

ibis_check_plink_prefix() {
    local p="$1"
    ibis_check_file "${p}.bed"
    ibis_check_file "${p}.bim"
    ibis_check_file "${p}.fam"
}

ibis_check_executable_or_cmd() {
    local x="$1"
    local label="$2"

    if command -v "$x" >/dev/null 2>&1; then
        return 0
    fi

    if [[ -x "$x" ]]; then
        return 0
    fi

    die "$label not found or not executable: $x"
}

ibis_safe_tag() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

ibis_strip_known_suffix() {
    local x
    x=$(basename "$1")
    x=${x%.vcf.gz}
    x=${x%.vcf}
    x=${x%.bcf}
    x=${x%.bed}
    x=${x%.bim}
    x=${x%.fam}
    echo "$x"
}

ibis_detect_input_format() {
    local input="$1"
    local requested="${2:-auto}"

    case "$requested" in
        auto|vcf|bcf|plink)
            ;;
        *)
            die "--ibis-input-format must be auto, vcf, bcf, or plink. Current: $requested"
            ;;
    esac

    if [[ "$requested" != "auto" ]]; then
        echo "$requested"
        return 0
    fi

    if [[ -s "${input}.bed" && -s "${input}.bim" && -s "${input}.fam" ]]; then
        echo "plink"
        return 0
    fi

    case "$input" in
        *.bed|*.bim|*.fam)
            echo "plink"
            ;;
        *.bcf)
            echo "bcf"
            ;;
        *.vcf|*.vcf.gz)
            echo "vcf"
            ;;
        *)
            die "cannot auto-detect --ibis-input format: $input. Supported: VCF/VCF.GZ, BCF, or PLINK bed/bim/fam prefix"
            ;;
    esac
}

ibis_plink_prefix_from_input() {
    local input="$1"

    case "$input" in
        *.bed)
            echo "${input%.bed}"
            ;;
        *.bim)
            echo "${input%.bim}"
            ;;
        *.fam)
            echo "${input%.fam}"
            ;;
        *)
            echo "$input"
            ;;
    esac
}

ibis_rewrite_bim_ids_to_chrpos() {
    local in_bim="$1"
    local out_bim="$2"

    awk 'BEGIN{OFS="\t"}
        NF < 6 {next}
        {
            chr=$1
            pos=$4
            id=chr ":" pos
            print chr,id,$3,pos,$5,$6
        }
    ' "$in_bim" > "$out_bim"
}

ibis_standardize_raw_seg_file() {
    local in_file="$1"
    local out_file="$2"

    if [[ ! -e "$in_file" ]]; then
        echo "[WARN] raw seg file not found, creating header-only raw seg: $in_file" >&2
        : > "$in_file"
    fi

    awk -v len_col="$IBIS_SEG_LENGTH_COL" \
        -v default_n="$IBIS_SEG_EXPECTED_NCOL" '
        BEGIN {
            FS="[ \t]+"
            OFS="\t"
            num_re="^-?[0-9.]+([eE][-+]?[0-9]+)?$"
            printed=0
        }

        function print_generic_header(prefix, n,    i) {
            for (i=1; i<=n; i++) {
                if (i > 1) printf OFS
                printf "%s_col%d", prefix, i
            }
            printf "\n"
        }

        function print_fields(    i) {
            for (i=1; i<=NF; i++) {
                if (i > 1) printf OFS
                printf "%s", $i
            }
            printf "\n"
        }

        NF == 0 {next}

        printed == 0 {
            if (len_col > NF || $(len_col) !~ num_re) {
                print_fields()
            } else {
                print_generic_header("seg", NF)
                print_fields()
            }
            printed=1
            next
        }

        { print_fields() }

        END {
            if (printed == 0) print_generic_header("seg", default_n)
        }
    ' "$in_file" > "$out_file"
}

ibis_standardize_coef_file() {
    local in_file="$1"
    local out_file="$2"

    ibis_check_file "$in_file"

    awk -v coef_pat="$IBIS_COEF_HEADER_PATTERN" \
        -v default_n="$IBIS_COEF_EXPECTED_NCOL" '
        BEGIN {
            FS="[ \t]+"
            OFS="\t"
            printed=0
        }

        function print_generic_header(prefix, n,    i) {
            for (i=1; i<=n; i++) {
                if (i > 1) printf OFS
                printf "%s_col%d", prefix, i
            }
            printf "\n"
        }

        function print_fields(    i) {
            for (i=1; i<=NF; i++) {
                if (i > 1) printf OFS
                printf "%s", $i
            }
            printf "\n"
        }

        function is_header_line() {
            if ($0 ~ coef_pat) return 1
            if (tolower($1) ~ /individual|sample|id1|iid1/) return 1
            if (tolower($2) ~ /individual|sample|id2|iid2/) return 1
            return 0
        }

        NF == 0 {next}

        printed == 0 {
            if (is_header_line()) {
                print_fields()
            } else {
                print_generic_header("coef", NF)
                print_fields()
            }
            printed=1
            next
        }

        { print_fields() }

        END {
            if (printed == 0) print_generic_header("coef", default_n)
        }
    ' "$in_file" > "$out_file"
}

ibis_merge_seg_coef() {
    local seg_file="$1"
    local coef_file="$2"
    local out_file="$3"

    if [[ ! -e "$seg_file" ]]; then
        echo "[WARN] raw seg file not found for merge, treating as empty: $seg_file" >&2
        : > "$seg_file"
    fi

    ibis_check_file "$coef_file"

    awk -v len_col="$IBIS_SEG_LENGTH_COL" \
        -v coef_pat="$IBIS_COEF_HEADER_PATTERN" '
        BEGIN {
            FS="[ \t]+"
            OFS="\t"
            num_re="^-?[0-9.]+([eE][-+]?[0-9]+)?$"
            coef_started=0
        }

        function print_generic_coef_header(n,    i) {
            for (i=1; i<=n; i++) {
                if (i > 1) printf OFS
                printf "coef_col%d", i
            }
            printf OFS "seg_pair_id" OFS "seg_total_cM" OFS "seg_n_segments" OFS "seg_filled" "\n"
        }

        function print_coef_header_with_seg(    i) {
            for (i=1; i<=NF; i++) {
                if (i > 1) printf OFS
                printf "%s", $i
            }
            printf OFS "seg_pair_id" OFS "seg_total_cM" OFS "seg_n_segments" OFS "seg_filled" "\n"
        }

        function is_coef_header_line() {
            if ($0 ~ coef_pat) return 1
            if (tolower($1) ~ /individual|sample|id1|iid1/) return 1
            if (tolower($2) ~ /individual|sample|id2|iid2/) return 1
            return 0
        }

        function print_coef_data_with_seg(    i, key, total, nseg, filled) {
            key = $1 ":" $2
            if (key in seg_total) {
                total = seg_total[key]
                nseg = seg_count[key]
                filled = 0
            } else {
                total = 0
                nseg = 0
                filled = 1
            }

            for (i=1; i<=NF; i++) {
                if (i > 1) printf OFS
                printf "%s", $i
            }
            printf OFS key OFS total OFS nseg OFS filled "\n"
        }

        FNR == NR {
            if (NF == 0) next
            if (len_col > NF || $(len_col) !~ num_re) next
            key = $1 ":" $2
            seg_total[key] += $(len_col)
            seg_count[key] += 1
            next
        }

        {
            if (NF == 0) next
            if (coef_started == 0) {
                if (is_coef_header_line()) {
                    print_coef_header_with_seg()
                    coef_started=1
                    next
                } else {
                    print_generic_coef_header(NF)
                    coef_started=1
                    print_coef_data_with_seg()
                    next
                }
            }
            print_coef_data_with_seg()
        }

        END {
            if (coef_started == 0) print_generic_coef_header(2)
        }
    ' "$seg_file" "$coef_file" > "$out_file"
}

ibis_prepare_plink_from_input() {
    local input="$1"
    local format="$2"
    local out_prefix="$3"

    local src_prefix
    local tmp_prefix

    mkdir -p "$(dirname "$out_prefix")"

    case "$format" in
        vcf)
            ibis_check_file "$input"
            local cmd=("$IBIS_PLINK2" --vcf "$input" --max-alleles 2)
            [[ -n "$IBIS_EXTRACT" ]] && cmd+=(--extract "$IBIS_EXTRACT")
            [[ -n "$IBIS_SET_ALL_VAR_IDS" ]] && cmd+=(--set-all-var-ids "$IBIS_SET_ALL_VAR_IDS")
            cmd+=(--make-bed --out "$out_prefix")
            echo "[IBIS] PLINK2 command: ${cmd[*]}"
            "${cmd[@]}"
            ;;

        bcf)
            ibis_check_file "$input"
            local cmd=("$IBIS_PLINK2" --bcf "$input" --max-alleles 2)
            [[ -n "$IBIS_EXTRACT" ]] && cmd+=(--extract "$IBIS_EXTRACT")
            [[ -n "$IBIS_SET_ALL_VAR_IDS" ]] && cmd+=(--set-all-var-ids "$IBIS_SET_ALL_VAR_IDS")
            cmd+=(--make-bed --out "$out_prefix")
            echo "[IBIS] PLINK2 command: ${cmd[*]}"
            "${cmd[@]}"
            ;;

        plink)
            src_prefix=$(ibis_plink_prefix_from_input "$input")
            ibis_check_plink_prefix "$src_prefix"
            tmp_prefix="${out_prefix}.source"
            cp "${src_prefix}.bed" "${tmp_prefix}.bed"
            cp "${src_prefix}.bim" "${tmp_prefix}.bim"
            cp "${src_prefix}.fam" "${tmp_prefix}.fam"

            if [[ -n "$IBIS_EXTRACT" ]]; then
                local cmd=("$IBIS_PLINK2" --bfile "$tmp_prefix" --extract "$IBIS_EXTRACT" --make-bed --out "$out_prefix")
                echo "[IBIS] PLINK2 command: ${cmd[*]}"
                "${cmd[@]}"
            else
                cp "${tmp_prefix}.bed" "${out_prefix}.bed"
                cp "${tmp_prefix}.bim" "${out_prefix}.bim"
                cp "${tmp_prefix}.fam" "${out_prefix}.fam"
            fi
            ;;

        *)
            die "internal error: unsupported IBIS input format: $format"
            ;;
    esac

    ibis_check_plink_prefix "$out_prefix"

    ibis_rewrite_bim_ids_to_chrpos "${out_prefix}.bim" "${out_prefix}.bim.reid"
    mv "${out_prefix}.bim.reid" "${out_prefix}.bim"

    if [[ "$IBIS_ADD_MAP_ENABLED" == "1" ]]; then
        ibis_check_executable_or_cmd "$IBIS_ADD_MAP" "IBIS add-map utility"
        ibis_check_file "$IBIS_MAP_FILE"
        "$IBIS_ADD_MAP" "${out_prefix}.bim" "$IBIS_MAP_FILE" > "${out_prefix}.bim.addmap"
        mv "${out_prefix}.bim.addmap" "${out_prefix}.bim"
    fi

    ibis_check_plink_prefix "$out_prefix"
}

run_ibis_only_workflow() {
    IBIS_ONLY=$(normalize_bool01 "$IBIS_ONLY")
    IBIS_ADD_MAP_ENABLED=$(normalize_bool01 "$IBIS_ADD_MAP_ENABLED")
    IBIS_KEEP_TEMP=$(normalize_bool01 "$IBIS_KEEP_TEMP")
    IBIS_PRINT_CMD_ONLY=$(normalize_bool01 "$IBIS_PRINT_CMD_ONLY")

    [[ -n "$IBIS_INPUT" ]] || die "--ibis-input is required with --ibis-only"

    ibis_check_executable_or_cmd "$IBIS_PLINK2" "plink2 for IBIS conversion"
    ibis_check_executable_or_cmd "$IBIS_BIN" "IBIS executable"
    [[ -n "$IBIS_EXTRACT" ]] && ibis_check_file "$IBIS_EXTRACT"

    if [[ "$IBIS_ADD_MAP_ENABLED" == "1" ]]; then
        [[ -n "$IBIS_ADD_MAP" ]] || die "--ibis-add-map is required unless --ibis-no-add-map is used"
        [[ -n "$IBIS_MAP_FILE" ]] || die "--ibis-map-file is required unless --ibis-no-add-map is used"
    fi

    validate_nonnegative_int "$IBIS_THREADS" "--ibis-threads"

    local format
    local input_base
    local work_dir
    local plink_prefix
    local ibis_run_prefix
    local cmd

    format=$(ibis_detect_input_format "$IBIS_INPUT" "$IBIS_INPUT_FORMAT")
    input_base=$(ibis_safe_tag "$(ibis_strip_known_suffix "$IBIS_INPUT")")

    if [[ -z "$IBIS_OUT_PREFIX" ]]; then
        IBIS_OUT_PREFIX="${OUTPUT_DIR}/${input_base}_ibisOut"
    fi

    if [[ -z "$IBIS_WORK_DIR" ]]; then
        IBIS_WORK_DIR="${OUTPUT_DIR}/ibis_work/${input_base}_$$"
    fi

    mkdir -p "$OUTPUT_DIR"
    mkdir -p "$(dirname "$IBIS_OUT_PREFIX")"
    rm -rf "$IBIS_WORK_DIR"
    mkdir -p "$IBIS_WORK_DIR"

    plink_prefix="${IBIS_WORK_DIR}/input_for_ibis"
    ibis_run_prefix="${IBIS_WORK_DIR}/ibis_run"

    echo "========================================"
    echo "[IBIS-ONLY]"
    echo "IBIS_INPUT=$IBIS_INPUT"
    echo "IBIS_INPUT_FORMAT=$format"
    echo "IBIS_OUT_PREFIX=$IBIS_OUT_PREFIX"
    echo "IBIS_WORK_DIR=$IBIS_WORK_DIR"
    echo "IBIS_EXTRACT=${IBIS_EXTRACT:-}"
    echo "IBIS_PLINK2=$IBIS_PLINK2"
    echo "IBIS_BIN=$IBIS_BIN"
    echo "IBIS_ADD_MAP_ENABLED=$IBIS_ADD_MAP_ENABLED"
    echo "IBIS_ADD_MAP=${IBIS_ADD_MAP:-}"
    echo "IBIS_MAP_FILE=${IBIS_MAP_FILE:-}"
    echo "IBIS_MIN_L=$IBIS_MIN_L"
    echo "IBIS_MT=$IBIS_MT"
    echo "IBIS_ER=$IBIS_ER"
    echo "IBIS_THREADS=$IBIS_THREADS"
    echo "========================================"

    ibis_prepare_plink_from_input "$IBIS_INPUT" "$format" "$plink_prefix"

    cmd=("$IBIS_BIN" -bfile "$plink_prefix" -min_l "$IBIS_MIN_L" -mt "$IBIS_MT" -er "$IBIS_ER" -t "$IBIS_THREADS" -printCoef -f "$ibis_run_prefix")

    echo "========================================"
    echo "[IBIS] Command:"
    printf '%q ' "${cmd[@]}"
    echo
    echo "========================================"

    if [[ "$IBIS_PRINT_CMD_ONLY" == "1" ]]; then
        echo "[INFO] --ibis-print-cmd-only set; not running IBIS"
        return 0
    fi

    "${cmd[@]}"

    rm -f "${IBIS_OUT_PREFIX}.raw.seg" \
          "${IBIS_OUT_PREFIX}.coef" \
          "${IBIS_OUT_PREFIX}.segcoef.tsv" \
          "${IBIS_OUT_PREFIX}.info.tsv"

    ibis_standardize_raw_seg_file \
        "${ibis_run_prefix}.seg" \
        "${IBIS_OUT_PREFIX}.raw.seg"

    ibis_standardize_coef_file \
        "${ibis_run_prefix}.coef" \
        "${IBIS_OUT_PREFIX}.coef"

    ibis_merge_seg_coef \
        "${ibis_run_prefix}.seg" \
        "${ibis_run_prefix}.coef" \
        "${IBIS_OUT_PREFIX}.segcoef.tsv"

    {
        echo -e "mode\tinput\tinput_format\textract_file\tplink_prefix\tibis_prefix\tout_prefix\traw_seg_file\tcoef_file\tsegcoef_file\tibis_min_l\tibis_mt\tibis_er\tthreads\tadd_map\tmap_file"
        echo -e "ibis_only\t${IBIS_INPUT}\t${format}\t${IBIS_EXTRACT:-NA}\t${plink_prefix}\t${ibis_run_prefix}\t${IBIS_OUT_PREFIX}\t${IBIS_OUT_PREFIX}.raw.seg\t${IBIS_OUT_PREFIX}.coef\t${IBIS_OUT_PREFIX}.segcoef.tsv\t${IBIS_MIN_L}\t${IBIS_MT}\t${IBIS_ER}\t${IBIS_THREADS}\t${IBIS_ADD_MAP:-NA}\t${IBIS_MAP_FILE:-NA}"
    } > "${IBIS_OUT_PREFIX}.info.tsv"

    if [[ "$IBIS_KEEP_TEMP" == "0" ]]; then
        rm -rf "$IBIS_WORK_DIR"
    else
        info "IBIS temp kept: $IBIS_WORK_DIR"
    fi

    echo "========================================"
    echo "[DONE] IBIS-only run finished"
    echo "${IBIS_OUT_PREFIX}.raw.seg"
    echo "${IBIS_OUT_PREFIX}.coef"
    echo "${IBIS_OUT_PREFIX}.segcoef.tsv"
    echo "${IBIS_OUT_PREFIX}.info.tsv"
    echo "========================================"
}



########################################
# 13. Standard lowpass-merge implementation
########################################

lowpass_msg() { echo "[LOWPASS] $*"; }
lowpass_warn() { echo "[LOWPASS][WARN] $*" >&2; }
lowpass_die() { echo "[LOWPASS][ERROR] $*" >&2; exit 1; }

lowpass_bool01() {
    normalize_bool01 "${1:-0}"
}

lowpass_check_file() {
    local f="$1"
    local label="${2:-file}"
    [[ -s "$f" ]] || lowpass_die "$label missing or empty: $f"
}

lowpass_check_prefix() {
    local p="$1"
    local label="${2:-PLINK prefix}"
    lowpass_check_file "${p}.bed" "$label .bed"
    lowpass_check_file "${p}.bim" "$label .bim"
    lowpass_check_file "${p}.fam" "$label .fam"
}

lowpass_check_exe_or_cmd() {
    local x="$1"
    local label="${2:-command}"
    if command -v "$x" >/dev/null 2>&1; then return 0; fi
    if [[ -x "$x" ]]; then return 0; fi
    lowpass_die "$label not found or not executable: $x"
}

lowpass_safe_tag() {
    basename "$1" | sed 's/\.vcf\.gz$//; s/\.bcf$//; s/\.vcf$//; s/\.bed$//; s/\.bim$//; s/\.fam$//; s/[^A-Za-z0-9._-]/_/g'
}

lowpass_expand_template() {
    local template="$1"
    local n="$2"
    local out="$template"
    out="${out//\{n\}/$n}"
    out="${out//\{N\}/$n}"
    out="${out//%n/$n}"
    echo "$out"
}

lowpass_resolve_highpass_prefix() {
    local n="$1"
    if [[ -n "${HIGHPASS_PREFIX_TEMPLATE:-}" ]]; then
        lowpass_expand_template "$HIGHPASS_PREFIX_TEMPLATE" "$n"
    elif [[ -n "${HIGHPASS_PREFIX:-}" ]]; then
        lowpass_expand_template "$HIGHPASS_PREFIX" "$n"
    else
        lowpass_die "HIGHPASS_PREFIX_TEMPLATE is required for lowpass-merge"
    fi
}

lowpass_read_manifest_file() {
    local in_file="$1"
    local out_file="$2"
    local default_prefix="${3:-unit}"

    lowpass_check_file "$in_file" "manifest list"

    awk -v pfx="$default_prefix" '
        BEGIN {FS="[ \t]+"; OFS="\t"}
        NF == 0 {next}
        $1 ~ /^#/ {next}
        NF == 1 {
            path=$1
            label=path
            sub(/^.*\//, "", label)
            gsub(/\.vcf\.gz$|\.vcf$|\.bcf$|\.bed$|\.bim$|\.fam$/, "", label)
            gsub(/[^A-Za-z0-9._-]/, "_", label)
            print label, path
            next
        }
        NF >= 2 {
            label=$1
            path=$2
            gsub(/[^A-Za-z0-9._-]/, "_", label)
            print label, path
            next
        }
    ' "$in_file" > "$out_file"

    [[ -s "$out_file" ]] || lowpass_die "no usable rows in manifest list: $in_file"
}

lowpass_make_unit_manifest() {
    local genotype_list="$1"
    local keep_list="${2:-}"
    local out_manifest="$3"
    local default_keep="${4:-}"

    local g_manifest k_manifest n_g n_k
    g_manifest="${out_manifest}.genotypes.tmp"
    k_manifest="${out_manifest}.keeps.tmp"

    lowpass_read_manifest_file "$genotype_list" "$g_manifest" "geno"
    n_g=$(wc -l < "$g_manifest" | awk '{print $1}')

    if [[ -n "$keep_list" ]]; then
        lowpass_read_manifest_file "$keep_list" "$k_manifest" "keep"
        n_k=$(wc -l < "$k_manifest" | awk '{print $1}')
    else
        : > "$k_manifest"
        n_k=0
    fi

    awk -v kg="$n_g" -v kk="$n_k" -v default_keep="$default_keep" '
        BEGIN {FS=OFS="\t"}
        FNR == NR {
            glabel[++ng]=$1
            gpath[ng]=$2
            next
        }
        {
            klabel[++nk]=$1
            kpath[nk]=$2
        }
        END {
            if (ng < 1) {
                print "ERROR: no genotype rows" > "/dev/stderr"
                exit 1
            }
            if (nk != 0 && nk != 1 && nk != ng) {
                print "ERROR: SNP_KEEP_FILE_LIST row count must be 1 or match GENOTYPE_FILE_LIST" > "/dev/stderr"
                print "genotype rows=" ng ", keep rows=" nk > "/dev/stderr"
                exit 1
            }
            for (i=1; i<=ng; i++) {
                if (nk == 0) {
                    keep=default_keep
                } else if (nk == 1) {
                    keep=kpath[1]
                } else {
                    keep=kpath[i]
                }
                print i, glabel[i], gpath[i], keep
            }
        }
    ' "$g_manifest" "$k_manifest" > "$out_manifest"

    rm -f "$g_manifest" "$k_manifest"
    [[ -s "$out_manifest" ]] || lowpass_die "failed to create lowpass unit manifest: $out_manifest"
}

lowpass_add_map_to_bim_if_enabled() {
    local prefix="$1"
    if [[ "${IBIS_ADD_MAP_ENABLED:-1}" == "1" ]]; then
        [[ -n "${IBIS_ADD_MAP:-}" ]] || lowpass_die "IBIS_ADD_MAP is required"
        [[ -n "${IBIS_MAP_FILE:-${MAP_FILE:-}}" ]] || lowpass_die "IBIS_MAP_FILE or MAP_FILE is required"
        local map_file="${IBIS_MAP_FILE:-${MAP_FILE:-}}"
        lowpass_check_exe_or_cmd "$IBIS_ADD_MAP" "IBIS add-map utility"
        lowpass_check_file "$map_file" "IBIS map file"
        "$IBIS_ADD_MAP" "${prefix}.bim" "$map_file" > "${prefix}.bim.addmap"
        mv "${prefix}.bim.addmap" "${prefix}.bim"
    fi
}

lowpass_rewrite_and_map_bim() {
    local prefix="$1"
    lowpass_check_prefix "$prefix" "PLINK prefix before BIM map update"
    ibis_rewrite_bim_ids_to_chrpos "${prefix}.bim" "${prefix}.bim.reid"
    mv "${prefix}.bim.reid" "${prefix}.bim"
    lowpass_add_map_to_bim_if_enabled "$prefix"
    lowpass_check_prefix "$prefix" "PLINK prefix after BIM map update"
}

lowpass_prepare_highpass_for_unit() {
    local highpass_prefix="$1"
    local keep_file="${2:-}"
    local out_prefix="$3"

    lowpass_check_prefix "$highpass_prefix" "high-pass PLINK prefix"
    lowpass_check_exe_or_cmd "$IBIS_PLINK2" "plink2"
    mkdir -p "$(dirname "$out_prefix")"

    local -a cmd
    cmd=("$IBIS_PLINK2" --bfile "$highpass_prefix" --make-bed --out "$out_prefix")
    [[ -n "$keep_file" ]] && { lowpass_check_file "$keep_file" "SNP keep file"; cmd+=(--extract "$keep_file"); }
    [[ -n "${INCLUDE_FAM:-}" ]] && { lowpass_check_file "$INCLUDE_FAM" "INCLUDE_FAM"; cmd+=(--keep "$INCLUDE_FAM"); }

    lowpass_msg "high-pass PLINK2 command: ${cmd[*]}"
    "${cmd[@]}"
    lowpass_rewrite_and_map_bim "$out_prefix"
}

lowpass_prepare_lowpass_for_unit() {
    local input="$1"
    local keep_file="${2:-}"
    local out_prefix="$3"

    lowpass_check_exe_or_cmd "$IBIS_PLINK2" "plink2"
    mkdir -p "$(dirname "$out_prefix")"

    local old_extract="${IBIS_EXTRACT:-}"
    local old_addmap="${IBIS_ADD_MAP_ENABLED:-1}"
    IBIS_EXTRACT="$keep_file"
    IBIS_ADD_MAP_ENABLED="${IBIS_ADD_MAP_ENABLED:-1}"

    local format
    format=$(ibis_detect_input_format "$input" "auto")
    lowpass_msg "preparing low-pass unit input=$input format=$format keep=${keep_file:-<none>}"
    ibis_prepare_plink_from_input "$input" "$format" "$out_prefix"

    IBIS_EXTRACT="$old_extract"
    IBIS_ADD_MAP_ENABLED="$old_addmap"
}

lowpass_merge_two_plink_prefixes() {
    local high_prefix="$1"
    local low_prefix="$2"
    local out_prefix="$3"

    lowpass_check_prefix "$high_prefix" "prepared high-pass prefix"
    lowpass_check_prefix "$low_prefix" "prepared low-pass prefix"
    lowpass_check_exe_or_cmd "$PLINK" "plink 1.9 for bed/bim/fam merge"
    mkdir -p "$(dirname "$out_prefix")"

    local -a cmd
    local missnp
    local high_nomiss_prefix
    local low_nomiss_prefix
    local -a hp_exclude_cmd
    local -a lp_exclude_cmd
    local -a retry_cmd

    missnp="${out_prefix}-merge.missnp"
    high_nomiss_prefix="${high_prefix}.nomissnp"
    low_nomiss_prefix="${low_prefix}.nomissnp"

    rm -f "$missnp"

    cmd=("$PLINK" --bfile "$high_prefix" --bmerge "${low_prefix}.bed" "${low_prefix}.bim" "${low_prefix}.fam" --make-bed --allow-no-sex --out "$out_prefix")

    lowpass_msg "merge command: ${cmd[*]}"
    if ! "${cmd[@]}"; then
        if [[ -s "$missnp" ]]; then
            lowpass_warn "PLINK merge failed and wrote $missnp"
            lowpass_warn "Retrying merge after excluding variants listed in missnp from both high-pass and low-pass prefixes"

            hp_exclude_cmd=("$PLINK" --bfile "$high_prefix" --exclude "$missnp" --make-bed --allow-no-sex --out "$high_nomiss_prefix")
            lp_exclude_cmd=("$PLINK" --bfile "$low_prefix" --exclude "$missnp" --make-bed --allow-no-sex --out "$low_nomiss_prefix")

            lowpass_msg "high-pass exclude missnp command: ${hp_exclude_cmd[*]}"
            "${hp_exclude_cmd[@]}"

            lowpass_msg "low-pass exclude missnp command: ${lp_exclude_cmd[*]}"
            "${lp_exclude_cmd[@]}"

            lowpass_check_prefix "$high_nomiss_prefix" "high-pass prefix after excluding missnp"
            lowpass_check_prefix "$low_nomiss_prefix" "low-pass prefix after excluding missnp"

            retry_cmd=("$PLINK" --bfile "$high_nomiss_prefix" --bmerge "${low_nomiss_prefix}.bed" "${low_nomiss_prefix}.bim" "${low_nomiss_prefix}.fam" --make-bed --allow-no-sex --out "$out_prefix")

            lowpass_msg "retry merge command: ${retry_cmd[*]}"
            if ! "${retry_cmd[@]}"; then
                if [[ -s "$missnp" ]]; then
                    lowpass_warn "retry merge also failed and wrote $missnp"
                fi
                return 1
            fi

            lowpass_msg "retry merge succeeded after excluding missnp variants"
        else
            lowpass_warn "PLINK merge failed but did not write $missnp"
            return 1
        fi
    fi

    lowpass_rewrite_and_map_bim "$out_prefix"
}

lowpass_run_ibis_on_prefix() {
    local merged_prefix="$1"
    local out_prefix="$2"
    local unit_label="$3"

    lowpass_check_prefix "$merged_prefix" "merged PLINK prefix"
    lowpass_check_exe_or_cmd "$IBIS_BIN" "IBIS executable"
    mkdir -p "$(dirname "$out_prefix")"

    local ibis_run_prefix="${out_prefix}.ibis_run"
    local -a cmd
    cmd=("$IBIS_BIN" -bfile "$merged_prefix" -min_l "$IBIS_MIN_L" -mt "$IBIS_MT" -er "$IBIS_ER" -t "$IBIS_THREADS" -printCoef -f "$ibis_run_prefix")

    lowpass_msg "IBIS command: ${cmd[*]}"
    "${cmd[@]}"

    ibis_standardize_raw_seg_file "${ibis_run_prefix}.seg" "${out_prefix}.raw.seg"
    ibis_standardize_coef_file "${ibis_run_prefix}.coef" "${out_prefix}.coef"
    ibis_merge_seg_coef "${ibis_run_prefix}.seg" "${ibis_run_prefix}.coef" "${out_prefix}.segcoef.tsv"

    {
        echo -e "unit_label\tmerged_prefix\tibis_prefix\tout_prefix\tibis_min_l\tibis_mt\tibis_er\tthreads\tmap_file"
        echo -e "${unit_label}\t${merged_prefix}\t${ibis_run_prefix}\t${out_prefix}\t${IBIS_MIN_L}\t${IBIS_MT}\t${IBIS_ER}\t${IBIS_THREADS}\t${IBIS_MAP_FILE:-${MAP_FILE:-NA}}"
    } > "${out_prefix}.info.tsv"
}

init_lowpass_collection() {
    local n="$1"
    [[ -n "$n" ]] || lowpass_die "simulation id is required"

    OUTPUT_DIR="${OUTPUT_DIR:-${OUT_DIR:-results}}"
    OUT_DIR="${OUT_DIR:-$OUTPUT_DIR}"
    TMP_DIR="${TMP_DIR:-${OUT_DIR}/tmp}"
    LOG_DIR="${LOG_DIR:-${OUT_DIR}/logs}"

    PLINK="${PLINK:-plink}"
    IBIS_PLINK2="${IBIS_PLINK2:-${PLINK2:-plink2}}"
    IBIS_BIN="${IBIS_BIN:-ibis}"
    IBIS_ADD_MAP="${IBIS_ADD_MAP:-${ADD_MAP:-}}"
    IBIS_MAP_FILE="${IBIS_MAP_FILE:-${MAP_FILE:-}}"
    IBIS_ADD_MAP_ENABLED="${IBIS_ADD_MAP_ENABLED:-1}"
    IBIS_MIN_L="${IBIS_MIN_L:-7}"
    IBIS_MT="${IBIS_MT:-500}"
    IBIS_ER="${IBIS_ER:-0.004}"
    IBIS_THREADS="${IBIS_THREADS:-4}"
    IBIS_SET_ALL_VAR_IDS="${IBIS_SET_ALL_VAR_IDS:-@:#}"
    IBIS_SEG_LENGTH_COL="${IBIS_SEG_LENGTH_COL:-9}"
    IBIS_SEG_EXPECTED_NCOL="${IBIS_SEG_EXPECTED_NCOL:-9}"
    IBIS_COEF_EXPECTED_NCOL="${IBIS_COEF_EXPECTED_NCOL:-2}"
    IBIS_COEF_HEADER_PATTERN="${IBIS_COEF_HEADER_PATTERN:-Individual1}"

    LOWPASS_SIM_N="$n"
    LOWPASS_HIGHPASS_PREFIX=$(lowpass_resolve_highpass_prefix "$n")

    RUN_TAG="${RUN_TAG:-lowpass_merge}"
    RUN_ID="${RUN_ID:-sim_${n}}"
    LOWPASS_COLLECTION_DIR="${LOWPASS_COLLECTION_DIR:-${OUT_DIR}/lowpass_merge/${RUN_ID}}"
    LOWPASS_WORK_DIR="${LOWPASS_WORK_DIR:-${TMP_DIR}/lowpass_merge/${RUN_ID}}"
    LOWPASS_LOG_DIR="${LOWPASS_LOG_DIR:-${LOG_DIR}/lowpass_merge/${RUN_ID}}"
    LOWPASS_UNIT_MANIFEST="${LOWPASS_UNIT_MANIFEST:-${LOWPASS_COLLECTION_DIR}/unit_manifest.tsv}"
    LOWPASS_STATUS_DIR="${LOWPASS_STATUS_DIR:-${LOWPASS_LOG_DIR}/status}"

    mkdir -p "$LOWPASS_COLLECTION_DIR" "$LOWPASS_WORK_DIR" "$LOWPASS_LOG_DIR" "$LOWPASS_STATUS_DIR"

    lowpass_check_prefix "$LOWPASS_HIGHPASS_PREFIX" "high-pass sim prefix"
    [[ -n "${GENOTYPE_FILE_LIST:-}" ]] || lowpass_die "GENOTYPE_FILE_LIST is required"

    local default_keep=""
    if [[ -n "${OVERLAP_SNP:-}" ]]; then
        default_keep="$OVERLAP_SNP"
    fi

    if [[ -n "${SNP_KEEP_FILE_LIST:-}" ]]; then
        lowpass_make_unit_manifest "$GENOTYPE_FILE_LIST" "$SNP_KEEP_FILE_LIST" "$LOWPASS_UNIT_MANIFEST" "$default_keep"
    else
        lowpass_make_unit_manifest "$GENOTYPE_FILE_LIST" "" "$LOWPASS_UNIT_MANIFEST" "$default_keep"
    fi

    {
        echo "LOWPASS_SIM_N=$LOWPASS_SIM_N"
        echo "RUN_TAG=$RUN_TAG"
        echo "RUN_ID=$RUN_ID"
        echo "LOWPASS_HIGHPASS_PREFIX=$LOWPASS_HIGHPASS_PREFIX"
        echo "LOWPASS_COLLECTION_DIR=$LOWPASS_COLLECTION_DIR"
        echo "LOWPASS_WORK_DIR=$LOWPASS_WORK_DIR"
        echo "LOWPASS_UNIT_MANIFEST=$LOWPASS_UNIT_MANIFEST"
        echo "GENOTYPE_FILE_LIST=${GENOTYPE_FILE_LIST:-}"
        echo "SNP_KEEP_FILE_LIST=${SNP_KEEP_FILE_LIST:-}"
        echo "OVERLAP_SNP=${OVERLAP_SNP:-}"
        echo "INCLUDE_FAM=${INCLUDE_FAM:-}"
        echo "IBIS_MAP_FILE=${IBIS_MAP_FILE:-}"
    } > "${LOWPASS_COLLECTION_DIR}/run.info"

    lowpass_msg "initialized lowpass collection for sim=$n"
    lowpass_msg "unit manifest: $LOWPASS_UNIT_MANIFEST"
}

process_one_lowpass_unit_for_sim() {
    local n="$1"
    local idx="$2"
    local label="$3"
    local genotype_input="$4"
    local keep_file="${5:-}"

    local unit_tag unit_dir hp_prefix lp_prefix merged_prefix ibis_out_prefix status_done status_failed
    unit_tag=$(printf '%04d_%s' "$idx" "$(lowpass_safe_tag "$label")")
    unit_dir="${LOWPASS_WORK_DIR}/${unit_tag}"
    hp_prefix="${unit_dir}/highpass"
    lp_prefix="${unit_dir}/lowpass"
    merged_prefix="${unit_dir}/merged"
    ibis_out_prefix="${LOWPASS_COLLECTION_DIR}/units/${unit_tag}/${unit_tag}_ibisOut"
    status_done="${LOWPASS_STATUS_DIR}/${unit_tag}.done"
    status_failed="${LOWPASS_STATUS_DIR}/${unit_tag}.failed"

    mkdir -p "$unit_dir" "$(dirname "$ibis_out_prefix")"
    rm -f "$status_done" "$status_failed"

    {
        echo "unit_index=$idx"
        echo "unit_label=$label"
        echo "genotype_input=$genotype_input"
        echo "keep_file=${keep_file:-}"
        echo "highpass_prefix=$LOWPASS_HIGHPASS_PREFIX"
        echo "unit_dir=$unit_dir"
        echo "ibis_out_prefix=$ibis_out_prefix"
    } > "${unit_dir}/unit.info"

    if {
        lowpass_prepare_highpass_for_unit "$LOWPASS_HIGHPASS_PREFIX" "$keep_file" "$hp_prefix" &&
        lowpass_prepare_lowpass_for_unit "$genotype_input" "$keep_file" "$lp_prefix" &&
        lowpass_merge_two_plink_prefixes "$hp_prefix" "$lp_prefix" "$merged_prefix" &&
        lowpass_run_ibis_on_prefix "$merged_prefix" "$ibis_out_prefix" "$label"
    }; then
        echo "$ibis_out_prefix" > "$status_done"
        lowpass_msg "unit finished: $unit_tag"
    else
        echo "$unit_tag" > "$status_failed"
        lowpass_warn "unit failed: $unit_tag"
        return 1
    fi
}

process_all_units_for_sim() {
    local n="$1"
    [[ -s "${LOWPASS_UNIT_MANIFEST:-}" ]] || lowpass_die "LOWPASS_UNIT_MANIFEST missing; run init_lowpass_collection first"

    local failures=0
    local idx label genotype_input keep_file

    lowpass_msg "processing lowpass units for sim=$n"
    while IFS=$'\t' read -r idx label genotype_input keep_file; do
        [[ -n "${idx:-}" ]] || continue
        lowpass_msg "processing unit idx=$idx label=$label"
        if ! process_one_lowpass_unit_for_sim "$n" "$idx" "$label" "$genotype_input" "${keep_file:-}"; then
            failures=$((failures + 1))
            if [[ "${LOWPASS_CONTINUE_ON_FAIL:-1}" != "1" ]]; then
                lowpass_die "stopping after failed unit $label"
            fi
        fi
    done < "$LOWPASS_UNIT_MANIFEST"

    if [[ "$failures" -gt 0 ]]; then
        lowpass_warn "finished with failed units: $failures"
        return 1
    fi

    lowpass_msg "all lowpass units finished for sim=$n"
}

collect_lowpass_units() {
    local n="$1"
    [[ -d "${LOWPASS_COLLECTION_DIR:-}" ]] || lowpass_die "LOWPASS_COLLECTION_DIR missing; run init_lowpass_collection first"

    local out_dir="$LOWPASS_COLLECTION_DIR"
    local summary="${out_dir}/lowpass_merge.sim_${n}.summary.tsv"
    local raw_seg_all="${out_dir}/lowpass_merge.sim_${n}.raw.seg.all.tsv"
    local coef_all="${out_dir}/lowpass_merge.sim_${n}.coef.all.tsv"
    local segcoef_all="${out_dir}/lowpass_merge.sim_${n}.segcoef.all.tsv"

    mkdir -p "$out_dir"

    {
        echo -e "unit_tag\tstatus\tibis_out_prefix"
        for f in "${LOWPASS_STATUS_DIR}"/*.done; do
            [[ -e "$f" ]] || continue
            unit=$(basename "$f" .done)
            prefix=$(cat "$f")
            echo -e "${unit}\tdone\t${prefix}"
        done
        for f in "${LOWPASS_STATUS_DIR}"/*.failed; do
            [[ -e "$f" ]] || continue
            unit=$(basename "$f" .failed)
            echo -e "${unit}\tfailed\tNA"
        done
    } > "$summary"

    : > "$raw_seg_all"
    : > "$coef_all"
    : > "$segcoef_all"

    local first_raw=1 first_coef=1 first_segcoef=1 f unit prefix
    while IFS=$'\t' read -r unit status prefix; do
        [[ "$unit" == "unit_tag" ]] && continue
        [[ "$status" == "done" ]] || continue

        f="${prefix}.raw.seg"
        if [[ -s "$f" ]]; then
            awk -v u="$unit" -v first="$first_raw" 'BEGIN{FS=OFS="\t"} NR==1 && first==1 {print "unit_tag", $0; next} NR==1 {next} {print u, $0}' "$f" >> "$raw_seg_all"
            first_raw=0
        fi

        f="${prefix}.coef"
        if [[ -s "$f" ]]; then
            awk -v u="$unit" -v first="$first_coef" 'BEGIN{FS=OFS="\t"} NR==1 && first==1 {print "unit_tag", $0; next} NR==1 {next} {print u, $0}' "$f" >> "$coef_all"
            first_coef=0
        fi

        f="${prefix}.segcoef.tsv"
        if [[ -s "$f" ]]; then
            awk -v u="$unit" -v first="$first_segcoef" 'BEGIN{FS=OFS="\t"} NR==1 && first==1 {print "unit_tag", $0; next} NR==1 {next} {print u, $0}' "$f" >> "$segcoef_all"
            first_segcoef=0
        fi
    done < "$summary"

    lowpass_msg "collection summary written: $summary"
    lowpass_msg "combined raw seg: $raw_seg_all"
    lowpass_msg "combined coef: $coef_all"
    lowpass_msg "combined segcoef: $segcoef_all"

    echo "========================================"
    echo "[DONE] lowpass-merge collection finished"
    echo "summary=$summary"
    echo "raw_seg_all=$raw_seg_all"
    echo "coef_all=$coef_all"
    echo "segcoef_all=$segcoef_all"
    echo "========================================"
}

# This file is intended to be sourced by main.sh. If run directly, print a small hint.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cat >&2 <<'USAGE'
This is a library file for mix_detect.
Use it through main.sh, for example:
  bash main.sh --config config.txt lowpass-merge 1
USAGE
fi
