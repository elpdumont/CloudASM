# Pre-requisities


##### Data
# Have a bucket already created with one folder per sample. 
# Each folder should include the zipped fastq files
# In the bucket, there should be a tsv file "samples.tsv" with each file name, its lane number, its read number (R1 or R2), and the size of the zipped fastq in GB

##### Authentification
# Be authentificated by gcloud (type "gcloud config list" to confirm)


########################## Copy and paste within the bash ################################

# GCP variables
PROJECT_ID="hackensack-tyco"
REGION_ID="us-central1"
ZONE_ID="us-central1-b"
DOCKER_IMAGE="gcr.io/hackensack-tyco/wgbs-asm"

# Names of the buckets (must be unique)
OUTPUT_B="em-encode-deux" # will be created by the script
REF_DATA_B="wgbs-ref-files" # See documentation for what it needs to contain

# Path of where you downloaded the Github scripts
SCRIPTS="$HOME/GITHUB_REPOS/wgbs-asm/"

# Create a bucket with the analysis
gsutil mb -c regional -l $REGION_ID gs://$OUTPUT_B 

# Create a local directory to download files
WD="$HOME/wgbs" && mkdir -p $WD && cd $WD

# Download the meta information about the samples and files to be analyzed.
gsutil cp gs://$INPUT_B/samples.tsv $WD
dos2unix samples.tsv 

# List of samples
awk -F "\t" \
    '{if (NR!=1) \
    print $1}' samples.tsv | uniq > sample_id.txt

echo "There are" $(cat sample_id.txt | wc -l) "samples to be analyzed"

########################## Unzip, rename, and split fastq files ################################

# Create an TSV file with parameters for the job
awk -v INPUT_B="${INPUT_B}" \
    -v OUTPUT_B="${OUTPUT_B}" \
    'BEGIN { FS=OFS="\t" } 
    {if (NR!=1) 
        print "gs://"INPUT_B"/"$1"/"$2, 
              $5".fastq", 
              "gs://"OUTPUT_B"/"$1"/split_fastq/*.fastq" 
     }' \
    samples.tsv > decompress.tsv 

# Add headers to the file
sed -i '1i --input ZIPPED\t--env FASTQ\t--output OUTPUT_FILES' decompress.tsv

# Launch job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --logging gs://$OUTPUT_B/logging/ \
  --disk-size 10 \
  --preemptible \
  --image $DOCKER_IMAGE \
  --command 'gunzip ${ZIPPED} && \
             mv ${ZIPPED%.gz} $(dirname "${ZIPPED}")/${FASTQ} && \
             split -l 1200000 \
                --numeric-suffixes --suffix-length=4 \
                --additional-suffix=.fastq \
                $(dirname "${ZIPPED}")/${FASTQ} \
                $(dirname "${OUTPUT_FILES}")/${FASTQ%fastq}' \
  --tasks decompress.tsv \
  --wait

########################## Trim a pair of fastq shards ################################

# Create an TSV file with parameters for the job
rm -f trim.tsv && touch trim.tsv

# Prepare inputs and outputs for each sample
while read SAMPLE ; do
  # Get the list of split fastq files
  gsutil ls gs://$OUTPUT_B/$SAMPLE/split_fastq > fastq_shard_${SAMPLE}.txt
  
  # Isolate R1 files
  cat fastq_shard_${SAMPLE}.txt | grep R1 > R1_files_${SAMPLE}.txt && sort R1_files_${SAMPLE}.txt
  # Isolate R2 files
  cat fastq_shard_${SAMPLE}.txt | grep R2 > R2_files_${SAMPLE}.txt && sort R2_files_${SAMPLE}.txt
  # Create a file repeating the output dir for the pair
  NB_PAIRS=$(cat R1_files_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt 
  for i in `seq 1 $NB_PAIRS` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/trimmed_fastq/*' >> output_dir_${SAMPLE}.txt
  done
  
  # Add the sample's 3 info (R1, R2, output folder) to the TSV file
  paste -d '\t' R1_files_${SAMPLE}.txt R2_files_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> trim.tsv
done < sample_id.txt

# Add headers to the file
sed -i '1i --input R1\t--input R2\t--output FOLDER' trim.tsv

# Print a message in the terminal
echo "There are" $(cat trim.tsv | wc -l) "to be launched"

# Submit job. Make sure you have enough resources
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --machine-type n1-standard-2 \
  --preemptible \
  --logging gs://$OUTPUT_B/logging/ \
  --command 'trim_galore \
      -a AGATCGGAAGAGCACACGTCTGAAC \
      -a2 AGATCGGAAGAGCGTCGTGTAGGGA \
      --quality 30 \
      --length 40 \
      --paired \
      --retain_unpaired \
      --fastqc \
      ${R1} \
      ${R2} \
      --output_dir $(dirname ${FOLDER})' \
  --tasks trim.tsv \
  --wait


########################## Align a pair of fastq shards ################################

# Prepare TSV file
echo -e "--input R1\t--input R2\t--output OUTPUT_DIR" > align.tsv

# Prepare inputs and outputs for each sample
while read SAMPLE ; do
  # Get the list of split fastq files
  gsutil ls gs://$OUTPUT_B/$SAMPLE/trimmed_fastq/*val*.fq > trimmed_fastq_shard_${SAMPLE}.txt
  
  # Isolate R1 files
  cat trimmed_fastq_shard_${SAMPLE}.txt | grep R1 > R1_files_${SAMPLE}.txt && sort R1_files_${SAMPLE}.txt
  # Isolate R2 files
  cat trimmed_fastq_shard_${SAMPLE}.txt | grep R2 > R2_files_${SAMPLE}.txt && sort R2_files_${SAMPLE}.txt
  
  # Create a file repeating the output dir for the pair
  NB_PAIRS=$(cat R1_files_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt 
  for i in `seq 1 $NB_PAIRS` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/aligned_per_chard/*' >> output_dir_${SAMPLE}.txt
  done
  
  # Add the sample's 3 info (R1, R2, output folder) to the TSV file
  paste -d '\t' R1_files_${SAMPLE}.txt R2_files_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> align.tsv
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(cat align.tsv | wc -l) "to be launched"

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --machine-type n1-standard-16 \
  --preemptible \
  --disk-size 40 \
  --logging gs://$OUTPUT_B/logging/ \
  --input-recursive REF_GENOME="gs://$REF_DATA_B/grc37" \
  --command 'bismark_nozip \
                -q \
                --bowtie2 \
                ${REF_GENOME} \
                -N 1 \
                -1 ${R1} \
                -2 ${R2} \
                --un \
                --score_min L,0,-0.2 \
                --bam \
                --multicore 3 \
                -o $(dirname ${OUTPUT_DIR})' \
  --tasks align.tsv \
  --wait

########################## Split chard's BAM by chromosome ################################

# Prepare TSV file
echo -e "--input BAM\t--output OUTPUT_DIR" > split.tsv

while read SAMPLE ; do
  gsutil ls gs://$OUTPUT_B/$SAMPLE/aligned_per_chard/*.bam > bam_per_chard_${SAMPLE}.txt
  NB_BAM=$(cat bam_per_chard_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt
  for i in `seq 1 $NB_BAM` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/bam_per_chard_and_chr/*' >> output_dir_${SAMPLE}.txt
  done
  paste -d '\t' bam_per_chard_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> split.tsv
done < sample_id.txt

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --disk-size 30 \
  --preemptible \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --script ${SCRIPTS}/split_bam.sh \
  --tasks split.tsv \
  --wait


########################## Merge all BAMs by chromosome, clean them ################################

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input BAM_FILES\t--output OUTPUT_DIR" > merge.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "${SAMPLE}\t${CHR}\tgs://$OUTPUT_B/$SAMPLE/bam_per_chard_and_chr/*chr${CHR}.bam\tgs://$OUTPUT_B/$SAMPLE/bam_per_chr/*" >> merge.tsv
  done
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(cat merge.tsv | wc -l) "to be launched"

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-highmem-8 \
  --preemptible \
  --disk-size 30 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --script ${SCRIPTS}/merge_bam.sh \
  --tasks merge.tsv \
  --wait


########################## Re-calibrate BAM  ################################

# This step is required by the variant call Bis-SNP

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input BAM\t--output OUTPUT_DIR" > recal.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "$SAMPLE\t$CHR\tgs://$OUTPUT_B/$SAMPLE/bam_per_chr/${SAMPLE}_chr${CHR}.bam\tgs://$OUTPUT_B/$SAMPLE/recal_bam_per_chr/*" >> recal.tsv
  done
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(tail -n +2 recal.tsv | wc -l) "to be launched"

# Re-calibrate the BAM files.
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-standard-16 \
  --disk-size 200 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --input REF_GENOME="gs://$REF_DATA_B/grc37/*" \
  --input VCF="gs://$REF_DATA_B/dbSNP150_grc37_GATK/no_chr_dbSNP150_GRCh37.vcf" \
  --script ${SCRIPTS}/bam_recalibration.sh \
  --tasks recal.tsv \
  --wait


########################## Variant call + create a 500bp window around them ################################

## TO BE TESTED

dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-standard-16 \
  --disk-size 200 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --env SAMPLE="A549-extract" \
  --env CHR="21" \
  --env BUCKET = "$OUTPUT_B" \
  --env PROJECT_ID="$PROJECT_ID" \
  --env DATASET_ID="$DATASET_ID" \
  --input BAM_BAI="gs://$OUTPUT_B/A549-extract/recal_bam_per_chr/A549-extract_chr21_recal.ba*" \
  --input REF_GENOME="gs://$REF_DATA_B/grc37/*" \
  --input VCF="gs://$REF_DATA_B/dbSNP150_grc37_GATK/no_chr_dbSNP150_GRCh37.vcf" \
  --output OUTPUT_DIR="gs://$OUTPUT_B/A549-extract/variants_per_chr/*" \
  --script ${SCRIPTS}/variant_call.sh \
  --wait

########################## Remove variants with zero CpG in their 500bp window ################################

dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-standard-16 \
  --disk-size 200 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --env SAMPLE="A549-extract" \
  --env CHR="21" \
  --env BUCKET = "$OUTPUT_B" \
  --env PROJECT_ID="$PROJECT_ID" \
  --env DATASET_ID="$DATASET_ID" \
  --input BED_500="gs://$OUTPUT_B/A549-extract/variants_per_chr/A549-extract_chr21_500bp.bed" \
  --input CPG_POS="gs://$REF_DATA_B/hg19_CpG_pos.bed" \
  --input VCF="gs://$REF_DATA_B/dbSNP150_grc37_GATK/no_chr_dbSNP150_GRCh37.vcf" \
  --output OUTPUT_DIR="gs://$OUTPUT_B/A549-extract/variants_per_chr/*" \
  --script ${SCRIPTS}/variant_list.sh \
  --wait