#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/cageseq
========================================================================================
 nf-core/cageseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/cageseq
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/cageseq --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Options:
      --genome                      Name of iGenomes reference

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
// Reference index path configuration
// Define these here - after the profiles are loaded with the iGenomes paths
params.star_index = params.genome ? params.genomes[ params.genome ].star ?: false : false
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.min_cluster = 100

// Validate inputs
if( params.star_index ){
    star_index = Channel
        .fromPath(params.star_index)
        .ifEmpty { exit 1, "STAR index not found: ${params.star_index}" }
}
else if ( params.fasta ){
    Channel.fromPath(params.fasta)
           .ifEmpty { exit 1, "Fasta file not found: ${params.fasta}" }
           .into { ch_fasta_for_star_index }
}
else {
    exit 1, "No reference genome specified!"
}

if( params.gtf ){
    Channel
        .fromPath(params.gtf)
        .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
        .into { gtf_makeSTARindex; gtf_makeHisatSplicesites; gtf_makeHISATindex; gtf_makeBED12;
              gtf_star; gtf_dupradar; gtf_featureCounts; gtf_stringtieFPKM }
} else {
    exit 1, "No GTF annotation specified!"
}


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  if (!workflow.workDir.startsWith('s3') || !params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for workDir and outdir parameters on AWSBatch!"
  // Check workDir/outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!workflow.workDir.startsWith('s3:') || !params.outdir.startsWith('s3:')) exit 1, "Workdir or Outdir not on S3 - specify S3 Buckets for each to run on AWSBatch!"
}


// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */
params.pairedEnd = false
Channel
    .fromFilePairs( params.reads, size: params.pairedEnd ? 2 : 1 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
    .into { read_files_fastqc; read_files_trimming }



// Header log info
log.info nfcoreHeader()
def summary = [:]
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['GTF Ref']          = params.gtf
summary['Trimming']         = params.trimming
summary['CutEcoP']          = params.cutEcop
summary['CutLinker']        = params.cutLinker
summary['CutG']             = params.cutG
summary['EcoSite']          = params.ecoSite
summary['LinkerSeq']        = params.linkerSeq
summary['Min. amount of reads to build a cluster']        = params.min_cluster
summary['Save Reference']   = params.saveReference
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-cageseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/cageseq Workflow Summary'
    section_href: 'https://github.com/nf-core/cageseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    STAR --version > v_star.txt
    cutadapt --version > v_cutadapt.txt
    samtools --version > v_samtools.txt
    bedtools --version > v_bedtools.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}



/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    input:
    set val(name), file(reads) from read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}


/*
 * STEP 2  - Build STAR index
 */
if(!params.star_index){

    process makeSTARindex {
        tag ch_fasta_for_star_index
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta from ch_fasta_for_star_index
        file gtf from gtf_makeSTARindex

        output:
        file "star" into star_index

        script:
        """
        mkdir star
        STAR \\
            --runMode genomeGenerate \\
            --runThreadN ${task.cpus} \\
            --sjdbGTFfile $gtf \\
            --sjdbOverhang 50 \\
            --genomeDir star/ \\
            --genomeFastaFiles $fasta
        """
    }
}


/*
 * STEP 3 - Cut Enzyme binding site at 5' and linker at 3'
 */
if(params.trimming){
    process trimming {
        tag "$prefix"
        publishDir "${params.outdir}/trimmed", mode: 'copy',
                saveAs: {filename ->
                    if (filename.indexOf(".fastq.gz") == -1)    "logs/$filename"
                    else "$filename" }

        input:
        set val(name), file(reads) from read_files_trimming

        output:
        file "*.fastq.gz" into trimmed_reads
        file "*.output.txt" into cutadapt_results

        script:
        prefix = reads.baseName.toString() - ~/(\.fq)?(\.fastq)?(\.gz)?$/
        // Cut Both EcoP and Linker
        if (params.cutEcop && params.cutLinker){
            """
            cutadapt -a ${params.ecoSite}...${params.linkerSeq} \\
            --match-read-wildcards \\
            -m 15 -M 45  \\
            -o ${reads.baseName}.trimmed.fastq.gz \\
            $reads \\
            > ${reads.baseName}.trimming.output.txt
            """
        }

        // Cut only EcoP site
        else if (params.cutEcop && !params.cutLinker){
            """
            mkdir trimmed
            cutadapt -g ^${params.ecoSite} \\
            -e 0 \\
            --match-read-wildcards \\
            --discard-untrimmed \\
            -o ${reads.baseName}.trimmed.fastq.gz \\
            $reads \\
            > ${reads.baseName}.trimming.output.txt
            """
        }

        // Cut only Linker
        else if (!params.cutEcop && params.cutLinker){
            """
            mkdir trimmed
            cutadapt -a ${params.linkerSeq}\$ \\
            -e 0 \\
            --match-read-wildcards \\
            -m 15 -M 45 \\
            -o ${reads.baseName}.trimmed.fastq.gz \\
            $reads \\
            > ${reads.baseName}.trimming.output.txt
            """
        }


    }
    // Make channels for all downstream programs
    trimmed_reads.into{ trimmed_fastqc_reads; trimmed_star_reads; trimmed_reads_cutG }


    // Post trimming QC
    process trimmed_fastqc {
        tag "${reads.baseName}"
        publishDir "${params.outdir}/trimmed/fastqc", mode: 'copy',
                saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

        input:
        file reads from trimmed_fastqc_reads

        output:
        file "*_fastqc.{zip,html}" into trimmed_fastqc_results

        script:
        """
        fastqc -q $reads
        """
    }
}


/**
 * STEP 4 - Remove added G from 5-end
 */
if (params.cutG){
    process cut_5G{

        input:
        file reads from trimmed_reads_cutG

        output:
        file "*.fastq.gz" into processed_reads

        script:
        """
        cutadapt -g ^G \\
        -e 0 --match-read-wildcards \\
        -o ${reads.baseName}.processed.fastq.gz \\
        $reads
        """
    }
}
else {
    trimmed_reads_cutG.into{ processed_reads }
}

process cut_artifacts {

        input:
        file reads from processed_reads

        output:
        file  "*.fastq.gz" into further_processed_reads

        script:
        """
        cutadapt -a file:assets/artifacte_3end.fasta \\
        -g file:assets/artifacts_5end.fasta -e 0.0 --discard-trimmed \\
        --match-read-wildcards -m 15 -O 21 \\
        -o ${reads.baseName}.further_processed.fastq.gz \\
        $reads \\
        > ${reads.baseName}.artifact_trimming.output.txt
        """

}


/**
 * STEP 5 - STAR alignment
 */

process star {
    tag "$prefix"
    publishDir "${params.outdir}/STAR", mode: 'copy',
            saveAs: {filename ->
                if (filename.indexOf(".bam") == -1) "logs/$filename"
                else  filename }

    input:
    file reads from further_processed_reads
    file index from star_index.collect()
    file gtf from gtf_star.collect()

    output:
    file '*.bam' into star_aligned
    file "*.out" into alignment_logs
    file "*SJ.out.tab"
    file "*Log.out" into star_log

    script:
    prefix = reads[0].toString() - ~/(.trimmed)?(\.fq)?(\.fastq)?(\.gz)?$/
    """
    STAR --genomeDir $index \\
        --sjdbGTFfile $gtf \\
        --readFilesIn $reads  \\
        --runThreadN ${task.cpus} \\
        --outSAMtype BAM SortedByCoordinate \\
        --readFilesCommand zcat \\
        --runDirPerm All_RWX \\
        --outFileNamePrefix $prefix \\
        --outFilterMatchNmin ${params.min_aln_length}
    """
}
// Split Star results
star_aligned.into { bam_count; bam_rseqc }



/**
 * STEP 6 - Get CTSS files
 */
process get_ctss {
    tag "${bam_count.baseName}"
    publishDir "${params.outdir}/ctss", mode: 'copy'

    input:
    file bam_count

    output:
    file "*.ctss.bed" into ctss_counts

    script:
    """
    bash make_ctss.sh $bam_count
    """
}


/**
 * STEP 7 - Cluster CTSS files
 */

process paraclu {
    tag "${ctss.baseName}"
    publishDir "${params.outdir}/ctss", mode: 'copy'

    input:
    file ctss from ctss_counts

    output:
    file "*" into ctss_clusters


    script:
    """
    process_ctss.py $ctss
    paraclu $params.min_cluster "${ctss.baseName}.bed_processed" > "${ctss.baseName}_clustered"
    paraclu-cut.sh "${ctss.baseName}_clustered" > "${ctss.baseName}_clustered_simplified"
    """
}

/*
 * STEP 8 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    file ('fastqc/*') from fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from software_versions_yaml
    file ('trimmed/*') from cutadapt_results.collect()
    file ('trimmed/fastqc/*') from trimmed_fastqc_results.collect().ifEmpty([])
    file ('alignment/*') from alignment_logs.collect()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    // TODO nf-core: get custom_content module working
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config \\
            -m star -m cutadapt -m fastqc -m custom_content
    """
}



/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/cageseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/cageseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/cageseq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/cageseq] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/cageseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/cageseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    if(workflow.success){
        log.info "${c_purple}[nf-core/cageseq]${c_green} Pipeline complete${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/cageseq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/cageseq v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
