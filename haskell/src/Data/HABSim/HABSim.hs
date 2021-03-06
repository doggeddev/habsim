module Data.HABSim.HABSim
  ( module Data.HABSim.Types
  , sim
  ) where

import Control.Lens
import Control.Monad.Writer
import qualified Data.DList as D
import qualified Data.HABSim.Internal as I
import Data.HABSim.Lens
import Data.HABSim.Types
import Data.HABSim.Grib2.CSVParse.Types
import qualified Data.HashMap.Lazy as HM
import Data.Maybe (fromMaybe)
import qualified Data.Vector as V

import Debug.Trace

sim
  :: Pitch
  -> Simulation
  -> V.Vector Int -- ^ Vector of pressures to round to from Grib file
  -> HM.HashMap Key GribLine
  -> (Simulation -> Bool) -- ^ We record the line when this predicate is met
  -> Writer (D.DList Simulation) Simulation
sim p
    simul@(Simulation
            sv
            (PosVel lat' lon' alt' vel_x' vel_y' vel_z')
            (Burst
              mass'
              bal_cd'
              par_cd'
              packages_cd'
              launch_time'
              burst_vol'
              b_volume'
              b_press'
              b_gmm'
              b_temp')
            (Wind (WindX wind_x') (WindY wind_y')))
    pressureList
    gribLines
    tellPred
  | baseGuard p = do
    let pv = PosVel lat' lon' alt' vel_x' vel_y' vel_z'
        bv = Burst
             mass'
             bal_cd'
             par_cd'
             packages_cd'
             launch_time'
             burst_vol'
             b_volume'
             b_press'
             b_gmm'
             b_temp'
        w = Wind windX' windY'
    return (Simulation sv pv bv w)
  | otherwise = do
    let sv' = sv { _simulationTime = sv ^. simulationTime + sv ^. increment }
        pv = PosVel nlat nlon nAlt nvel_x nvel_y nvel_z
        bv = Burst
             mass'
             bal_cd'
             par_cd'
             packages_cd'
             launch_time'
             burst_vol'
             (pitch p nVol b_volume')
             (pitch p pres b_press')
             b_gmm'
             (pitch p (_temp temp) b_temp')
        w = Wind windX' windY'
        s = Simulation sv' pv bv w
    when (tellPred simul) $
      tell (D.singleton s)
    sim p s pressureList gribLines tellPred
  where
    -- The guard to use depends on the pitch
    baseGuard Ascent = b_volume' >= burst_vol'
    baseGuard Descent = alt' < 0

    -- Getting pressure and density at current altitude
    PressureDensity pres dens temp = I.altToPressure alt'

    -- Calculating volume, radius, and crossectional area
    nVol = I.newVolume b_press' b_temp' b_volume' pres (_temp temp)
    Meter nbRad = I.spRadFromVol nVol
    nCAsph  = I.cAreaSp nbRad

    gdens = I.gas_dens (Mass b_gmm') pres temp

    -- Calculating buoyant force
    f_buoy = I.buoyancy dens gdens nVol

    -- Calculate drag force for winds
    f_drag_x =
      case p of
        Ascent -> I.drag dens vel_x' (windIntpX ^. windX) bal_cd' nCAsph
        Descent -> I.drag dens vel_x' (windIntpX ^. windX) packages_cd' 1
    f_drag_y =
      case p of
        Ascent -> I.drag dens vel_y' (windIntpY ^. windY) bal_cd' nCAsph
        Descent -> I.drag dens vel_y' (windIntpY ^. windY) packages_cd' 1
    f_drag_z = 
      case p of
        Ascent -> I.drag dens vel_z' 0 bal_cd' nCAsph
        Descent -> I.drag dens vel_z' 0 par_cd' 1
    -- Net forces in z
    f_net_z =
      case p of
        Ascent -> f_buoy - ((-1 * f_drag_z) + (I.force mass' I.g))
        Descent -> f_drag_z - (I.force mass' I.g)


    -- Calculate Kenimatics
    accel_x = I.accel f_drag_x mass'
    accel_y = I.accel f_drag_y mass'
    accel_z = I.accel f_net_z mass'
    nvel_x = I.velo vel_x' accel_x sv
    nvel_y = I.velo vel_y' accel_y sv
    nvel_z = I.velo vel_z' accel_z sv
    Altitude disp_x = I.displacement (Altitude 0.0) nvel_x accel_x sv
    Altitude disp_y = I.displacement (Altitude 0.0) nvel_y accel_y sv
    nAlt = I.displacement alt' nvel_z accel_z sv

    -- Calculate change in corrdinates
    -- Because of the relatively small changes, we assume a spherical earth
    bearing = atan2 disp_x disp_y
    t_disp = (disp_x ** 2 + disp_y ** 2) ** (1 / 2)
    ang_dist = t_disp / I.er

    latr = lat' * (pi / 180)
    lonr = lon' * (pi / 180)
    nlatr =
      asin (sin latr * cos ang_dist + cos latr * sin ang_dist * cos bearing)
    nlonr =
      lonr +
      atan2 (sin bearing * sin ang_dist * cos latr)
            (cos ang_dist - (sin latr * sin nlatr))
    nlat = nlatr * (180 / pi)
    nlon = nlonr * (180 / pi)

    (flat, flon, clat, clon) =
      I.latLonBox (Latitude lat') (Longitude lon') 0.25

    windCurrentDef lat lon =
      fromMaybe
      (WindX wind_x', WindY wind_y')
      (I.windFromLatLon
        lat
        lon
        (I.roundToClosest (pres/100) pressureList)
        gribLines)

    (WindX (WindMs windX1), WindY (WindMs windY1)) = windCurrentDef flat flon
    (WindX (WindMs windX2), WindY (WindMs windY2)) = windCurrentDef flat clon
    (WindX (WindMs windX3), WindY (WindMs windY3)) = windCurrentDef clat flon
    (WindX (WindMs windX4), WindY (WindMs windY4)) = windCurrentDef clat clon
    (windX', windY') = windCurrentDef (Latitude lat') (Longitude lon')

    windIntpX =
      WindX . WindMs $
        I.biLinIntp
        lat'
        lon'
        windX1
        windX2
        windX3
        windX4
        (flat ^. latitude)
        (clat ^. latitude)
        (flon ^. longitude)
        (clon ^. longitude)

    windIntpY =
      WindY . WindMs $
        I.biLinIntp
        lat'
        lon'
        windY1
        windY2
        windY3
        windY4
        (flat ^. latitude)
        (clat ^. latitude)
        (flon ^. longitude)
        (clon ^. longitude)
