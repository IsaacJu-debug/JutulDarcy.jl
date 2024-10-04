function coarsen_reservoir_model(fine_model::MultiModel, partition; functions = Dict(), well_arg = Dict(), kwarg...)
    reservoir = reservoir_domain(fine_model)
    creservoir = coarsen_reservoir(reservoir, partition, functions = functions)

    wells = get_model_wells(fine_model)
    cwells = []
    for (k, well) in pairs(wells)
        if haskey(well_arg, k)
            wkw = well_arg[k]
        else
            wkw = NamedTuple()
        end
        push!(cwells, coarsen_well(well, creservoir, reservoir, partition; wkw...))
    end
    split_wells = !haskey(fine_model.models, :Facility)

    fine_reservoir_model = reservoir_model(fine_model)
    sys = fine_reservoir_model.system

    coarse_model, = setup_reservoir_model(creservoir, sys;
        wells = cwells,
        split_wells = split_wells,
        # context = fine_reservoir_model.context,
        kwarg...
    )
    coarse_reservoir_model = reservoir_model(coarse_model)
    # Variables etc.
    ncoarse = maximum(partition)
    subcells = zeros(Int, ncoarse)
    for i in 1:ncoarse
        subcells[i] = findfirst(isequal(i), partition)
    end
    coarse_keys = keys(coarse_model.models)
    fine_keys = keys(fine_model.models)
    @assert sort([coarse_keys...]) == sort([fine_keys...]) "Coarse keys $coarse_keys does not match fine keys $fine_keys"
    for mkey in keys(coarse_model.models)
        cm = coarse_model.models[mkey]
        fm = fine_model.models[mkey]
        if mkey == :Reservoir
            fmap = FiniteVolumeGlobalMap(subcells, Int[])
            fmap::FiniteVolumeGlobalMap
        elseif mkey in keys(wells)
            # A bit hackish to get this working for wells
            nnode = length(unique(cm.domain.representation.perforations.self))
            fmap = FiniteVolumeGlobalMap(ones(Int, nnode), Int[])
        else
            fmap = TrivialGlobalMap()
        end
        for vartype in [:parameters, :primary, :secondary]
            vars = Jutul.get_variables_by_type(fm, vartype)
            cvars = Jutul.get_variables_by_type(cm, vartype)
            empty!(cvars)
            for (k, var) in pairs(vars)
                cvars[k] = Jutul.subvariable(var, fmap)
            end
        end
    end
    coarse_parameters = setup_parameters(coarse_model)
    return (coarse_model, coarse_parameters)
end

function coarsen_reservoir(D::DataDomain, partition; functions = Dict())
    if !haskey(functions, :permeability)
        functions[:permeability] = Jutul.CoarsenByHarmonicAverage()
    end
    if !haskey(functions, :porosity)
        functions[:porosity] = Jutul.CoarsenByVolumeAverage()
    end
    return Jutul.coarsen_data_domain(D, partition, functions = functions)
end

function coarsen_well(well, creservoir::DataDomain, reservoir::DataDomain, partition; kwarg...)
    cells = unique(partition[well.perforations.reservoir])
    is_simple = well isa SimpleWell
    if is_simple
        d = well.reference_depth
    else
        d = well.top.reference_depth
    end
    return setup_well(creservoir, cells;
        name = well.name,
        reference_depth = d,
        simple_well = is_simple,
        kwarg...
    )
end

struct CoarsenByPoreVolume <: Jutul.AbstractCoarseningFunction
    fine_pv::Vector{Float64}
end

function Jutul.inner_apply_coarsening_function(finevals, fine_indices, op::CoarsenByPoreVolume, coarse, fine, name, entity)
    subvols = op.fine_pv[fine_indices]
    return sum(finevals.*subvols)/sum(subvols)
end

function coarsen_reservoir_state(coarse_model, fine_model, fine_state0; functions = Dict(), default = missing)
    coarse_state0 = Dict{Symbol, Any}()

    if haskey(fine_state0, :Reservoir)
        # We ignore the wells, better to re-initialize
        fine_state0 = fine_state0[:Reservoir]
    end
    coarse_rmodel = reservoir_model(coarse_model)
    fine_rmodel = reservoir_model(fine_model)

    coarse_reservoir = reservoir_domain(coarse_rmodel)
    fine_reservoir = reservoir_domain(fine_rmodel)

    if ismissing(default)
        pv = pore_volume(fine_reservoir)
        default = CoarsenByPoreVolume(pv)
    end

    ncoarse = number_of_cells(coarse_reservoir)
    for (k, v) in pairs(fine_state0)
        if associated_entity(fine_rmodel[k]) == Cells() && eltype(v)<:AbstractFloat
            if v isa AbstractVector
                coarseval = zeros(ncoarse)
            else
                coarseval = zeros(size(v, 1), ncoarse)
            end
            f = get(functions, k, default)
            coarse_state0[k] = Jutul.apply_coarsening_function!(coarseval, v, f, coarse_reservoir, fine_reservoir, k, Cells())
        end
    end
    return setup_reservoir_state(coarse_model, coarse_state0)
end
