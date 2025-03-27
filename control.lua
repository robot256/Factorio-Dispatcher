require("util")

local NAME_DISPATCHER_ENTITY = "train-stop-dispatcher"
local SIGNAL_DISPATCH = {type="virtual", name="dispatcher-station"}
local NAME_SEPARATOR = "."
local NAME_SEPARATOR_REGEX = "%."

-- Only use on_tick event when there is a train waiting for a signal at a station
-- Use this function to restore the correct event state when the save is loaded or trains are added/removed
function register_on_tick()
  if table_size(storage.awaiting_dispatch) > 0 then
    script.on_event(defines.events.on_tick, tick)
  else
    script.on_event(defines.events.on_tick, nil)
  end
end

script.on_load(register_on_tick)

-- Initiate storage variables when activating the mod
script.on_init(function()
  -- Store all the train awaiting dispatch
  -- (we need to keep track of these trains in order to dispatch a train when a dispatch signal is sent)
  storage.awaiting_dispatch = {}

  -- Store all the stations per surface
  -- (we need it cached for performance reasons)
  storage.stations = {}
  storage.station_ids = {}

  storage.debug = false
  
  register_on_tick()
end)


-- When configuration is changed (new mod version, etc.)
script.on_configuration_changed(function(data)
  if data.mod_changes and data.mod_changes.Dispatcher then
    local old_version = data.mod_changes.Dispatcher.old_version
    local new_version = data.mod_changes.Dispatcher.new_version

    -- Mod version upgraded
    if old_version and old_version < "1.0.2" then
      storage.debug = false
    end

    local debug_temp = storage.debug
    storage.debug = true

    -- Build the list of stations on the map (also migrates old data and registers units)
    build_list_stations()
    -- Scrub train list to remove ones that don't exist anymore
    scrub_trains()

    -- Complete the migration if no dispatched trains remain in list
    if storage.dispatched then
      if next(storage.dispatched) then
        debug("Dispatcher: WARNING! Could not migrate all dispatched trains. Please upload save file to the Dispatcher mod page.")
      else
        debug("Dispatcher: Completed migrating dispatched trains to temporary schedule records.")
        storage.dispatched = nil
      end
    end

    storage.debug = debug_temp
    
    register_on_tick()
  end
end)


-- Add new station to storage.stations if it meets our criteria
function add_station(entity)
  local name = entity.backer_name
  local id = entity.unit_number
  local surface_index = entity.surface.index
  if entity.name == NAME_DISPATCHER_ENTITY or name:match(NAME_SEPARATOR_REGEX.."[123456789]%d*$") then
    if not storage.stations[surface_index] then
      storage.stations[surface_index] = {}
    end
    if not storage.stations[surface_index][name] then
      storage.stations[surface_index][name] = {}
      storage.stations[surface_index][name][id] = entity
      debug("Added first station: ", game.surfaces[surface_index].name.."/"..name)
    else
      storage.stations[surface_index][name][id] = entity
      debug("Added station: ", game.surfaces[surface_index].name.."/"..name)
    end
    storage.station_ids[id] = {entity=entity, surface_index=surface_index, name=name}
    script.register_on_object_destroyed(entity)
  else
    --debug("Ignoring new station: ", game.surfaces[surface_index].name.."/"..name)
  end
end

-- Remove station from storage.stations if it is in the list
function remove_station(entity, old_name)
  local name = old_name or entity.backer_name
  local id = entity.unit_number
  local surface_index = entity.surface.index
  if storage.stations[surface_index] and storage.stations[surface_index][name] and storage.stations[surface_index][name][id] then
    storage.stations[surface_index][name][id] = nil
    if not next(storage.stations[surface_index][name]) then
      storage.stations[surface_index][name] = nil
      debug("Removed last station named: ", game.surfaces[surface_index].name.."/"..name)
      if not next(storage.stations[surface_index]) then
        storage.stations[surface_index] = nil
        debug("Removed last station from surface "..game.surfaces[surface_index].name)
      end
    else
      debug("Removed station: ", game.surfaces[surface_index].name.."/"..name)
    end
  end
  storage.station_ids[id] = nil
end

-- Add stations when built/revived
function entity_built(event)
  local entity = event.created_entity or event.entity
  add_station(entity)
end
script.on_event(defines.events.on_built_entity, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.on_robot_built_entity, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.script_raised_built, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.script_raised_revive, entity_built, {{filter="type", type="train-stop"}})

-- Add station or copy train data when cloned
function entity_cloned(event)
  local entity = event.destination
  if entity.type == "train-stop" then
    add_station(entity)
  elseif entity.type == "locomotive" and event.source then
    local previous_id = event.source.train.id
    if storage.awaiting_dispatch[previous_id] and storage.awaiting_dispatch[previous_id].schedule then
      -- Copy saved schedule from source to the cloned train, because it starts in manual mode
      local new_train = entity.train
      debug("Cloning saved schedule from train "..tostring(previous_id).." to train "..tostring(new_train.id)..": "..serpent.line(storage.awaiting_dispatch[previous_id].schedule))
      new_train.schedule = storage.awaiting_dispatch[previous_id].schedule
    end
  end
end
script.on_event(defines.events.on_entity_cloned, entity_cloned, {{filter="type", type="train-stop"}, {filter="type", type="locomotive"}})

-- Remove station when mined/destroyed
-- Purge this station by unit number only
function object_destroyed(event)
  if event.type == defines.target_type.entity then
    local id = event.useful_id
    local data = storage.station_ids[id]
    if data and storage.stations[data.surface_index] and storage.stations[data.surface_index][data.name] then
      local surface_index = data.surface_index
      local name = data.name
      storage.stations[surface_index][name][id] = nil
      if not next(storage.stations[surface_index][name]) then
        storage.stations[surface_index][name] = nil
        debug("Removed last station named: ", game.surfaces[surface_index].name.."/"..name)
        if not next(storage.stations[surface_index]) then
          storage.stations[surface_index] = nil
          debug("Removed last station from surface "..game.surfaces[surface_index].name)
        end
      else
        debug("Removed station: ", game.surfaces[surface_index].name.."/"..name)
      end
    end
    storage.station_ids[id] = nil
  end
end
script.on_event(defines.events.on_object_destroyed, object_destroyed)

-- Update station when renamed by player or script
function entity_renamed(event)
  local entity = event.entity
  if entity.type == "train-stop" then
    remove_station(entity, event.old_name)
    add_station(entity)
  end
end
script.on_event(defines.events.on_entity_renamed, entity_renamed)


-- Build list of stations
function build_list_stations()
  storage.stations = {}
  storage.station_ids = {}
  local stations = game.train_manager.get_train_stops{}
  for _,station in pairs(stations) do
    add_station(station)
  end
  debug("Stations list rebuilt")
end


-- Scrub list of trains
function scrub_trains()
  -- Look for trains awaiting dispatch that disappeared during configuration change
  for id,ad in pairs(storage.awaiting_dispatch) do
    if not(ad.train and ad.train.valid) then
      storage.awaiting_dispatch[id] = nil
      debug("Scrubbed train " .. id .. " from Awaiting Dispatch list.")
    end
  end
  register_on_tick()
  -- Migrate currently dispatched trains to use temporary stops, so we don't have to track them anymore
  if storage.dispatched then
    for id,d in pairs(storage.dispatched) do
      if not(d.train and d.train.valid) then
        storage.dispatched[id] = nil
        debug("Scrubbed train " .. id .. " from Dispatched list.")
      else
        -- Migrate schedule to use a temporary stop (2.0 API version)
        local schedule = d.train.get_schedule()  -- get train's schedule object_destroyed
        local schedule_current = schedule.current
        -- Get the record our dispatch data was pointing towards
        local dispatched_record = (d.current <= schedule.get_record_count()) and schedule.get_record{schedule_index=d.current}
        if dispatched_record and dispatched_record.station and dispatched_record.station == d.station then
          dispatched_record.temporary = true
          dispatched_record.index = {schedule_index=d.current}  -- insertion point goes in the argument table
          schedule.remove_record{schedule_index=d.current}
          schedule.add_record(dispatched_record)
          schedule.go_to_station(schedule_current)
          storage.dispatched[id] = nil
          debug("Converted train "..id.." to temporary destination and removed from Dispatched list.")
        else
          debug("Did not convert train"..id.." to temporary destination.")
        end
      end
    end
  end
end


-- Track train state change
function train_changed_state(event)
  local train = event.train
  local id = train.id
  local train_schedule = train.get_schedule()
  
  -- A train that is awaiting dispatch cannot change state. Restore schedule if appropriate
  if storage.awaiting_dispatch[id] then
    local station_name = storage.awaiting_dispatch[id].station_name
    if storage.awaiting_dispatch[id].schedule then
      -- There is a stored schedule, restore it
      local stored_schedule = storage.awaiting_dispatch[id].schedule
      train_schedule.set_records(stored_schedule.records)
      train_schedule.go_to_station(stored_schedule.current)
      if train.manual_mode then
        debug("Train #", id, " set to manual mode while awaiting dispatch: schedule reset")
      elseif not storage.awaiting_dispatch[id].station or not storage.awaiting_dispatch[id].station.valid then
        debug("Train #", id, " was waiting at a dispatcher that no longer exists: schedule reset")
      else
        debug("Train #", id, " left the dispatcher: schedule reset")
      end
    else
      -- Schedule was either completely overwritten, or player sent train to another stop
      -- Try to find the temporary waiting station we added and remove it
      local found = false
      for i=1,train_schedule.get_record_count() do
        local record = train_schedule.get_record{schedule_index=i}
        if record.temporary and record.station == station_name then
          train_schedule.remove_record{schedule_index=i}
          -- If train was pathing to the waiting stop, send it to the previous record (the actual dispatcher arrival)
          if train_schedule.current >= i then
            train_schedule.go_to_station(train_schedule.current - 1)
          end
          found = true
          break
        end
      end
      if found then
        train_schedule.set_records(stored_schedule.records)
        train_schedule.go_to_station(stored_schedule.current)
        if train.manual_mode then
          debug("Train #", id, " set to manual mode while awaiting dispatch: schedule reset")
        elseif not storage.awaiting_dispatch[id].station or not storage.awaiting_dispatch[id].station.valid then
          debug("Train #", id, " was waiting at a dispatcher that no longer exists: schedule reset")
        else
          debug("Train #", id, " left the dispatcher: schedule reset")
        end
      else
        debug("Dispatcher: WARNING! Train #", id, " no longer awaiting dispatch but schedule was not reset.")
      end
    end
    storage.awaiting_dispatch[id] = nil
  end

  -- When a train arrives at a dispatcher
  local train_station = train.station
  if train.state == defines.train_state.wait_station and train_station and train_station.name == NAME_DISPATCHER_ENTITY then
    -- Add the train to the storage variable storing all the trains awaiting dispatch
    local station_name = train_station.backer_name
    storage.awaiting_dispatch[id] = {train=train, station=train_station, station_name=station_name}

    -- Change the train schedule so that the train stays at the station
    local wait_record = {station=station_name, temporary=true, wait_conditions={{type="circuit", compare_type="or", condition={}}}, index={schedule_index=train_schedule.current+1}}
    train_schedule.add_record(wait_record)
    train_schedule.go_to_station(train_schedule.current + 1)
    debug("Train #", id, " has arrived to dispatcher ", train_station.surface.name, "/", station_name, ": awaiting dispatch")
  end
  
  register_on_tick()
end
script.on_event(defines.events.on_train_changed_state, train_changed_state)


-- Check for any locomotives in the train
local function has_locos(train)
  if next(train.locomotives.front_movers) then
    return true
  end
  if next(train.locomotives.back_movers) then
    return true
  end
  return false
end

-- Track uncoupled trains (because the train id changes)
function train_created(event)
  local ad
  local train = event.train
  if event.old_train_id_1 and event.old_train_id_2 then
    if storage.awaiting_dispatch[event.old_train_id_1] then
      ad = storage.awaiting_dispatch[event.old_train_id_1]
    elseif storage.awaiting_dispatch[event.old_train_id_2] then
      ad = storage.awaiting_dispatch[event.old_train_id_2]
    end
    local train_schedule = train.get_schedule()
    if ad then
      if train_schedule.get_record_count() > 0 then
        train_schedule.set_records(ad.schedule.records)
        train_schedule.go_to_station(ad.schedule.current)
        --train.manual_mode = false
        storage.awaiting_dispatch[train.id] = nil
        debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while awaiting dispatch: new train #", train.id, " schedule reset, and mode set to automatic")
      else
        debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while awaiting dispatch: new train #", train.id, " set to manual because it has no schedule")
      end
      storage.awaiting_dispatch[event.old_train_id_2] = nil
      storage.awaiting_dispatch[event.old_train_id_1] = nil
    end
  elseif event.old_train_id_1 then
    ad = storage.awaiting_dispatch[event.old_train_id_1]
    if ad then
      train_schedule.set_records(ad.schedule.records)
      train_schedule.go_to_station(ad.schedule.current)
      if has_locos(train) then
        train.manual_mode = false
        debug("Train #", event.old_train_id_1, " was split to create train #", train.id, " while awaiting dispatch: train schedule reset, and mode set to automatic")
      else
        debug("Train #", event.old_train_id_1, " was split to create train #", train.id, " while awaiting dispatch: train schedule reset, and mode set to manual because it has no locomotives")
      end
    end
  end
end
script.on_event(defines.events.on_train_created, train_created)


-- Executed every tick when a train is waiting for a signal
function tick()
  for id,ad in pairs(storage.awaiting_dispatch) do

    -- Ensure that the train still exists
    if not ad.train or not ad.train.valid then
      storage.awaiting_dispatch[id] = nil
      debug("Train #", id, " no longer exists: removed from awaiting dispatch list")

    else
      -- Get the dispatch signal at the dispatcher, check if it is a positive number
      local signal = ad.station.get_signal(SIGNAL_DISPATCH, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)

      if signal and signal > 0 then
        local dispatcher_name = ad.station.backer_name
        local name = dispatcher_name .. NAME_SEPARATOR .. tostring(signal)
        local surface = ad.station.surface
        local surface_index = surface.index

        if storage.stations[surface_index] and storage.stations[surface_index][name] then

          -- Search for valid destination station
          local found = false
          for _,station in pairs(storage.stations[surface_index][name]) do
            -- Check that the station exists and has space available
            if station.valid and station.trains_count < station.trains_limit then
              local cb = station.get_control_behavior()
              -- Check that the station in not disabled (disabled station still shows positive train limit)
              if not cb or not cb.disabled then
                found = true
                break
              end
            end
          end

          if found then
            -- Get schedule of waiting train
            local train_schedule = ad.train.get_schedule()
            local current_index = train_schedule.current
            if (current_index > 1 and
                train_schedule.get_record{schedule_index=current_index}.temporary and
                train_schedule.get_record{schedule_index=current_index-1}.station == dispatcher_name) then

              -- Currently at a temporary waiting stop. Delete it.
              train_schedule.remove_record{schedule_index=current_index}
              train_schedule.go_to_station(current_index - 1)

            elseif ad.schedule then
              -- Waiting at a real stop or the schedule got messed up. Use stored schedule
              train_schedule.set_records(ad.schedule.records)
              train_schedule.go_to_station(ad.schedule.current)

            else
              debug("Dispatcher: WARNING! Train "..id.." waiting at "..dispatcher_name.." could not be dispatched because schedule is missing.")
              train_schedule = nil
            end

            if train_schedule then
              local current_index = train_schedule.current
              local current_record = train_schedule.get_record{schedule_index=current_index}
              if current_record.temporary then
                -- Arrived at this dispatcher with a temporary stop. Replace it with the dispatched destination, conditions stay the same.
                current_record.station = name
                current_record.index = {schedule_index=current_index}
                train_schedule.add_record(current_record)
                train_schedule.remove_record{schedule_index=current_index+1}
                train_schedule.go_to_station(current_index)
              else
                -- Arrived at this dispatcher with a permanent stop. Add the temporary dispatched destination and copy the conditions.
                current_record.station = name
                current_record.temporary = true
                current_record.index = {schedule_index=current_index+1}
                train_schedule.add_record(current_record)
                train_schedule.go_to_station(current_index + 1)
              end

              ad.train.manual_mode = false

              for _, player in pairs(game.players) do
                if player.surface == surface then
                  player.create_local_flying_text({text={"dispatcher.train-dispatched-message",id,name}, position=ad.station.position, speed=1, time_to_live=200})
                end
              end
              debug("Train #", id, " has been dispatched to station "..surface.name.."/"..name)
            end

            -- This train is not awaiting dispatch any more
            storage.awaiting_dispatch[id] = nil

          else
            --debug("Train #", ad.train.id, " can't find any enabled station '", name, "'")
          end
        else
          --debug("Train #", ad.train.id, " can't find any station named '", name, "'")
        end
      end
    end
  end
  if table_size(storage.awaiting_dispatch) == 0 then
    script.on_event(defines.events.on_tick, nil)
  end
end



function any_to_string(...)
  local text = ""
  for _, v in ipairs{...} do
    if type(v) == "table" then
      text = text..serpent.block(v)
    else
      text = text..tostring(v)
    end
  end
  return text
end

function print_game(...)
  game.print(any_to_string(...))
end

-- Debug (print text to player console)
function debug(...)
  if storage.debug then
    print_game(...)
  end
end

-- Debug command
function cmd_debug(params)
  local action = params.parameter
  if not action then
    if storage.debug then
      action = "disable"
    else
      action = "enable"
    end
  end
  if action == "disable" then
    storage.debug = false
    print_game("Debug mode disabled")
  elseif action == "enable" then
    storage.debug = true
    print_game("Debug mode enabled")
  elseif action == "dump" then
    for v, data in pairs(storage) do
      print_game(v, ": ", data)
    end
  elseif action == "dumplog" then
    for v, data in pairs(storage) do
      log(any_to_string(v, ": ", data))
    end
    print_game("Dump written to log file")
  end
end
commands.add_command("dispatcher-debug", {"command-help.dispatcher-debug"}, cmd_debug)

if script.active_mods["gvv"] then require("__gvv__.gvv")() end

------------------------------------------------------------------------------------
--                    FIND LOCAL VARIABLES THAT ARE USED GLOBALLY                 --
--                              (Thanks to eradicator!)                           --
------------------------------------------------------------------------------------
setmetatable(_ENV,{
  __newindex=function (self,key,value) --locked_global_write
    error('\n\n[ER Global Lock] Forbidden global *write*:\n'
      .. serpent.line{key=key or '<nil>',value=value or '<nil>'}..'\n')
    end,
  __index   =function (self,key) --locked_global_read
    error('\n\n[ER Global Lock] Forbidden global *read*:\n'
      .. serpent.line{key=key or '<nil>'}..'\n')
    end ,
  })
