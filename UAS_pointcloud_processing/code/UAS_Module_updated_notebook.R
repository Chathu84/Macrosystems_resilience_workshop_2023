
##title: "Tree delineations using drone based point cloud data"

##########################################

## In this module we use unmanned aerial system derived point cloud data to delineate individual tree locations and their individual canopy areas.

#check the required libraries are available. If not install required libraries.

list.of.packages <- c("tidyverse","lidR","terra","raster","rgdal","ForestTools","RCSF","sp","sf","stars","rgl")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)


## Load the required libraries. We use several libraries that can help with loading, reading spatial data including raster and point cloud data, 
## analyse those data, and to visualize and write the spatial data back into a desired location.

library(tidyverse)
library(lidR)
library(terra)
library(raster)
library(rgdal)
library(ForestTools)
library(RCSF)
library(sp)
library(sf)
library(stars)
library(rgl)
rgl::setupKnitr(autoprint = TRUE)

#install.packages("Rcpp", repos="https://rcppcore.github.io/drat")


################################################################
# set working environment
wd = "D:/Carbon_dynamics/UAS-processing/Test"
setwd(wd)


# explore the raw data and load the raw data file names

file_list = dir("D:/Carbon_dynamics/UAS-processing/Test", pattern = ".las", full.names = FALSE, ignore.case = TRUE) 
names_to_cloud = substr(file_list, 2, nchar(file_list)-4) # truncate the file names.


################################################################

#get the raw point cloud data from the data storage and display the point cloud. The point cloud data was produced 
#in Agisoft metashape proprietary software using photogrammetry and used hundreds of RBG images collected using a phantom 4 pro drone.
# A point cloud is a three dimensional discrete set of points space. Each point can be identified using a set of three Cartesian coordinates (X, Y, and Z).
# The set of point cloud can represent a 3D landscape, or a shape, or an object. 

cropped_dense_point_cloud_fname <- file.path(paste0(file_list[2]))
dense_point_cloud <- lidR::readLAS(cropped_dense_point_cloud_fname)
plot(dense_point_cloud,color = "Z")

#read digital surface model in raster format. Digital surface model here was created using proprietary software called Agisoft metashape. 
main_dsm = raster(file.path(paste0("DSM_NIWOT_plt2.tif")))

#crop the digital surface model (a raster file that contains surface elevation data)
test_dsm = crop(main_dsm,dense_point_cloud)
plot(test_dsm, main="Digital Surface Model")

writeRaster(x = test_dsm, filename = "cropped_dsm.tif", overwrite = TRUE)



################################################################
#assign variables and file saving location
site_name <- "Test"
flight_datetime <- "07-26-2022"

# directories to be created in this script
new_dir <- file.path("data", site_name, flight_datetime)

  if(!dir.exists(new_dir)) {
    dir.create(new_dir, recursive = TRUE)
  }


classified_dense_pc <- file.path("data", site_name,flight_datetime, paste0( names_to_cloud[2],"_classified2.las"))
  
cropped_dtm_fname <- file.path("data", site_name,flight_datetime, paste0(names_to_cloud[2], "_dtm2.tif"))
cropped_chm_fname <- file.path("data", site_name,flight_datetime,paste0(names_to_cloud[2], "_chm2.tif"))

cropped_ttops_fname <- file.path("data", site_name, flight_datetime, paste0(names_to_cloud[2], "_ttops_cropped2.gpkg"))
cropped_crowns_fname <- file.path("data", site_name, flight_datetime,paste0(names_to_cloud[2], "_crowns_cropped2.gpkg"))



################################################################
# create digital terrain model. In this section, we classify the points into ground and above ground points. Then use ground points to generate digital terrain model.
# The digital terrain model represent the topography of the bare ground underneath the trees, grass or shrubs.

dense_point_cloud[["X scale factor"]] = 0.001
dense_point_cloud[["Y scale factor"]] = 0.001

classified_dense_point_cloud <- lidR::classify_ground(las = dense_point_cloud,
                                                      algorithm = csf(sloop_smooth = TRUE,
                                                                      class_threshold = 0.25,
                                                                      cloth_resolution = 0.50, # was 0.5 before,
                                                                      rigidness = 1,
                                                                      iterations = 500,
                                                                      time_step = 0.65))

plot(classified_dense_point_cloud,color = "Classification")


if(!file.exists(classified_dense_pc)) {
  lidR::writeLAS(las = classified_dense_point_cloud, file = classified_dense_pc)
}


################################################################
# create canopy height model
dtm <- lidR::grid_terrain(las = classified_dense_point_cloud,
                          res = 0.10, # was 0.5 and 0.25 before
                          algorithm = tin())

#raster::writeRaster(x = dtm, filename = cropped_dtm_fname, overwrite = TRUE)
terra::writeRaster(x = dtm, filename = cropped_dtm_fname, overwrite = TRUE)

dtm_resamp <- raster::resample(x = dtm, y = test_dsm, method = "bilinear")

plot(dtm_resamp, main = "Digital terrain model")

# generate canopy height model. canopy height model is a raster image where the values in pixel represents the canopy height at that pixel.
# The canopy height here is the difference between digital surface and the digital terrain models.
chm <- test_dsm - dtm_resamp
  
chm_smooth <- raster::focal(chm, w = matrix(1, 3, 3), mean)
chm_smooth[raster::getValues(chm_smooth) < 0] <- 0

terra::writeRaster(x = chm_smooth, filename = cropped_chm_fname, overwrite = TRUE)
plot(chm_smooth, main =  "Canopy height model")



################################################################
# detecting tree tops. In this section we navigate through each and every cell with a given moving window filter. The vwf or the variable window filter algorithm developed by Popescu and Wynne (2004). The size of the window changes based on the height of the cell on which it is centered.  from the cell that has the maximum height in the canopy height model and assign them to a certain tree. Thus it is important to define the variable size window at the first. Here we use 
# the equation "x^2*c + x*b + a" where x is the pixel height.  


chm = terra::rast(cropped_chm_fname)
max_chm = chm@ptr$range_max
print(max_chm)


a <- 0.3 # was 0.3
b <- 0.04 #0.04
c <- 0 #0

lin <- function(x){x^2*c + x*b + a} # window filter function to use in next step

ttops <- ForestTools::vwf(CHM = raster::raster(chm), 
                          winFun = lin, 
                          minHeight = 0.5,# change min height based on research objectives 
                          maxWinDiameter = 99) %>% 
   sf::st_as_sf()
    
ttop_crd = ttops %>%
    mutate(x = unlist(map(ttops$geom,1)),
           y = unlist(map(ttops$geom,2)))



plot(chm_smooth,main =  "Canopy height model")

points(ttop_crd$x,ttop_crd$y)

if(!file.exists(cropped_ttops_fname)) {
  
  sf::st_write(obj = ttops, dsn = cropped_ttops_fname, delete_dsn = TRUE)
}


################################################################
# tree crown delineation. In this section we segment tree crowns of each tree top we generated in the earlier step. We use "mcws" watershed algorithm.  


  # read necessary data products
ttops <- sf::st_read(cropped_ttops_fname)
  # the {terra} package will be replacing {raster}, so here's how this is done in {terra}
  
  

non_spatial_ttops <-
  ttops %>%
  dplyr::mutate(x = st_coordinates(.)[, 1],
                y = st_coordinates(.)[, 2]) %>%
  sf::st_drop_geometry()
  
crowns <-
  ttops %>%
  ForestTools::mcws(CHM = raster::raster(chm), minHeight = 0.5, format = "raster") %>% # minheight was 1 m before
  setNames(nm = "treeID") %>%
  st_as_stars() %>%
  st_as_sf(merge = TRUE) %>%
  dplyr::left_join(non_spatial_ttops, by = "treeID") %>% 
  sf::st_make_valid()

for (i in 1:nrow(crowns)) {
  this_point <- sf::st_drop_geometry(crowns[i, ]) %>% sf::st_as_sf(coords = c("x", "y"), crs = sf::st_crs(crowns))
  crowns[i, "point_in_crown"] <- as.vector(sf::st_intersects(x = this_point, y = crowns[i, ], sparse = FALSE))
}

crowns <-
  crowns %>% 
  dplyr::filter(point_in_crown) %>% 
  dplyr::select(-point_in_crown)

if(!file.exists(cropped_crowns_fname)) {
  sf::st_write(obj = crowns, dsn = cropped_crowns_fname, delete_dsn = TRUE)
}


################################################################

basemap= raster("D:/Carbon_dynamics/UAS-processing/Test/orthomosaic_NIWOT_plt2.tif")

crop_ortho = crop(basemap,test_dsm)

#pal = colorRampPalette(c("green", "brown"))
plot(chm)
plot(crowns$geometry, add=TRUE)

plot(crop_ortho)
plot(crowns$geometry, add=TRUE)



