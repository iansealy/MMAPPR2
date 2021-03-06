#' Generate potential causative mutations and consequences in peak regions
#'
#' Follows the \code{\link{peakRefinement}} step and produces a
#' \code{\linkS4class{MmapprData}} object ready for
#' \code{\link{outputMmapprData}}.
#'
#' @param mmapprData The \code{\linkS4class{MmapprData}} object to be analyzed.
#'
#' @return A \code{\linkS4class{MmapprData}} object with the \code{candidates}
#'   slot filled with a \code{\link[GenomicRanges]{GRanges}} object for each
#'   peak chromosome containing variants and predicted consequences from
#'   Ensembl's Variant Effect Predictor.
#' @export
#'
#' @examples
#' if (requireNamespace('MMAPPR2data', quietly=TRUE)
#'         & all(Sys.which(c("samtools", "vep")) != "")) {
#'     mmappr_param <- MmapprParam(refFasta = MMAPPR2data::goldenFasta(),
#'                                wtFiles = MMAPPR2data::exampleWTbam(),
#'                                mutFiles = MMAPPR2data::exampleMutBam(),
#'                                species = "danio_rerio",
#'                                outputFolder = tempOutputFolder())
#' }
#' \dontrun{
#' md <- new('MmapprData', param = mmappr_param)
#' postCalcDistMD <- calculateDistance(md)
#' postLoessMD <- loessFit(postCalcDistMD)
#' postPrePeakMD <- prePeak(postLoessMD)
#' postPeakRefMD <- peakRefinement(postPrePeakMD)
#'
#' postCandidatesMD <- generateCandidates(postPeakRefMD)
#' }
generateCandidates <- function(mmapprData) {

    #get GRanges representation of peak
    mmapprData@candidates <- lapply(mmapprData@peaks, .getPeakRange)

    #call variants in peak
    mmapprData@candidates <- lapply(mmapprData@candidates,
                                    FUN=.getVariantsForRange,
                                    param=mmapprData@param)

    #run VEP
    mmapprData@candidates <- lapply(mmapprData@candidates,
                                    FUN=.runVEPForVariants,
                                    param=mmapprData@param)

    #filter out low impact variants
    mmapprData@candidates <- lapply(mmapprData@candidates, .filterVariants)

    #density score and order variants
    mmapprData@candidates <-
        lapply(names(mmapprData@candidates), function(seqname) {
            densityFunction <- mmapprData@peaks[[seqname]]$densityFunction
            stopifnot(!is.null(densityFunction))
            variants <- mmapprData@candidates[[seqname]]
            variants <-
                .densityScoreAndOrderVariants(variants, densityFunction)
            return(variants)
        })

    #transfer names
    names(mmapprData@candidates) <- names(mmapprData@peaks)


    return(mmapprData)
}


.getPeakRange <- function(peakList) {
    ir <- IRanges::IRanges(start=as.numeric(peakList$start),
                  end=as.numeric(peakList$end),
                  names=peakList$seqname)

    gr <- GenomicRanges::GRanges(seqnames=names(ir),
                  ranges=ir)
    return(gr)
}


.getVariantsForRange <- function(inputRange, param) {
    # merge files in desired region if there are multiple
    mergedBam <- file.path(outputFolder(param), 'merged.tmp.bam')
    if (length(param@mutFiles) < 2) mutBam <- param@mutFiles[[1]]
    else{
        mutBam <- mergeBam(param@mutFiles,
                           destination=mergedBam,
                           region=inputRange)
    }

    # create param for variant calling
    tallyParam <- TallyVariantsParam(genome=param@refGenome,
                                     which=inputRange,
                                     indels=TRUE
    )

    resultVr <- callVariants(mutBam, tally.param=tallyParam)

    if (file.exists(mergedBam)) file.remove(mergedBam)

    if (length(resultVr) > 0) {
        # need sampleNames to convert to VCF; using mutant file names
        Biobase::sampleNames(resultVr) <-
            paste0(names(param@mutFiles),
                   collapse = " -- ")
        S4Vectors::mcols(resultVr) <- NULL
        return(resultVr)
    }
    else return(NULL)
}

.tmpPeakVcf <- function(param) file.path(outputFolder(param), 'peak.tmp.vcf')

.runVEPForVariants <- function(inputVariants, param){
    vepFlags <- vepFlags(param)
    stopifnot(is(vepFlags, "VEPFlags"))
    stopifnot(is(inputVariants, 'VRanges'))

    vcf <- .tmpPeakVcf(param)
    tryCatch({
        VariantAnnotation::writeVcf(inputVariants, vcf)
        resultGRanges <- ensemblVEP::ensemblVEP(vcf, vepFlags)
    }, error=function(e) {
        stop(e)
    },finally={
        if (file.exists(vcf)) file.remove(vcf)
    })

    return(resultGRanges)
}


.filterVariants <- function(candidateGRanges) {
    filter <-
        GenomicRanges::mcols(candidateGRanges)$IMPACT != 'LOW'
    filter[is.na(filter)] <- TRUE
    return(candidateGRanges[filter])
}


.densityScoreAndOrderVariants <- function(candidateGRanges, densityFunction) {
    #density calculation
    positions <- BiocGenerics::start(candidateGRanges) +
        ((BiocGenerics::width(candidateGRanges) - 1) / 2)
    densityCol <- vapply(positions, densityFunction, FUN.VALUE=numeric(1))
    GenomicRanges::mcols(candidateGRanges)$peakDensity <- densityCol

    #re-order
    orderVec <- order(densityCol, decreasing=TRUE)
    candidateGRanges <- candidateGRanges[orderVec]

    return(candidateGRanges)
}
