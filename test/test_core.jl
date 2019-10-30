let
    id = ActionID(1)
    id += 1
end
let
    Random.seed!(0);

    # Define Environment
    vtx_grid = initialize_dense_vtx_grid(8,8);
    env_graph = initialize_grid_graph_from_vtx_grid(vtx_grid);
    dist_matrix = get_dist_matrix(env_graph);

    # Define project
    N = 5; M = 10;
    object_ICs = [OBJECT_AT(j,j) for j in 1:M];
    object_FCs = [OBJECT_AT(j,j+M) for j in 1:M];
    robot_ICs = [ROBOT_AT(i,i) for i in 1:N];
    spec = construct_random_project_spec(M,object_ICs,object_FCs;max_parents=3);
    operations = spec.operations;
    root_ops = map(op->op.id, spec.operations[collect(spec.root_nodes)])
    problem_spec = TaskGraphProblemSpec(N=N,M=M,D=dist_matrix);

    # Construct Partial Project Schedule
    project_schedule = ProjectSchedule();
    for pred in object_ICs
       add_to_schedule!(project_schedule, problem_spec, pred, get_object_id(pred))
    end
    for pred in robot_ICs
       add_to_schedule!(project_schedule, problem_spec, pred, get_robot_id(pred))
    end
    for op in operations
       operation_id = op.id
       add_to_schedule!(project_schedule, problem_spec, op, operation_id)
    end
    # add root nodes
    for operation_id in root_ops
        v = get_vtx(project_schedule, operation_id)
        push!(project_schedule.root_nodes, v)
        project_schedule.weights[v] = 1.0
    end
    # Fill in gaps in project schedule (except for GO assignments)
    for op in operations
        operation_id = op.id
        for object_id in get_input_ids(op)
            # add action sequence
            object_ic = get_object_ICs(project_schedule)[object_id]
            pickup_station_id = get_id(get_location_id(object_ic))
            object_fc = object_FCs[object_id]
            dropoff_station_id = get_id(get_location_id(object_fc))
            # TODO Handle collaborative tasks
            # if is_single_robot_task(project_spec, object_id)
            robot_id = -1
            add_single_robot_delivery_task!(project_schedule,problem_spec,robot_id,
                object_id,pickup_station_id,dropoff_station_id)
            # elseif is_collaborative_robot_task(project_spec, object_id)
            # end
            action_id = ActionID(get_num_actions(project_schedule))
            add_edge!(project_schedule, action_id, operation_id)
        end
        for object_id in get_output_ids(op)
            add_edge!(project_schedule, operation_id, ObjectID(object_id))
        end
    end
    project_schedule

    # Formulate MILP problem
    G = get_graph(project_schedule);
    t0_ = Dict{AbstractID,Float64}();
    nR = ones(M); # number of robots required for each task
    NV = nv(G);
    assignments = [];
    Δt = map(v->get_path_spec(project_schedule, v).min_path_duration, vertices(G));
    robot_ids = sort(collect(keys(get_robot_ICs(project_schedule))));
    object_ids = sort(collect(keys(get_object_ICs(project_schedule))));
    robot_id_map = Dict(RobotID(k)=>i for (i,k) in enumerate(robot_ids));
    object_id_map = Dict(ObjectID(k)=>j for (j,k) in enumerate(object_ids));
    @assert length(object_id_map) == M;
    n_robots = length(robot_id_map); # different than N because dummy robots have been added

    optimizer = Gurobi.Optimizer;
    TimeLimit=100;
    OutputFlag=0;
    model = Model(with_optimizer(optimizer,
        TimeLimit=TimeLimit,
        OutputFlag=OutputFlag
        ));
    @variable(model, t0[1:NV] >= 0.0); # initial times for all nodes
    @variable(model, tF[1:NV] >= 0.0); # final times for all nodes
    # Assignment matrix x
    @variable(model, x[1:n_robots,1:M], binary = true); # x[i,j] ∈ {0,1}
    @constraint(model, x * ones(M) .<= 1);              # each robot may have no more than 1 task
    @constraint(model, x' * ones(n_robots) .== nR);     # each task must have exactly 1 assignment
    for (id,t) in t0_
        v = get_vtx(project_schedule, id)
        @constraint(model, t0[v] == t)
    end
    for (robot_id,object_id) in assignments
        i = robot_id_map[robot_id]
        j = object_id_map[object_id]
        @constraint(model, x[i,j] == 1)
    end
    # other constraints
    Mm = 10000 # for big-M constraints
    for v in vertices(G)
        @constraint(model, tF[v] >= t0[v] + Δt[v])
        for v2 in inneighbors(G,v)
            @constraint(model, t0[v] >= tF[v2])
        end
    end
    # what edges to add?
    @variable(model, X[1:nv(G),1:nv(G)], binary = true); # x[i,j] ∈ {0,1}
    missing_successors      = Dict{Int,Dict}()
    missing_predecessors    = Dict{Int,Dict}()
    n_successors            = zeros(nv(G))
    n_predecessors          = zeros(nv(G))
    for v in vertices(G)
        node = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v))
        for (key,val) in eligible_successors(node)
            n_successors[v] += 1
        end
        for (key,val) in eligible_predecessors(node)
            n_predecessors[v] += 1
        end
        missing_successors[v] = eligible_successors(node)
        for v2 in outneighbors(G,v)
            @constraint(model, X[v,v2] == 1)
            id2 = get_vtx_id(project_schedule, v2)
            node2 = get_node_from_id(project_schedule, id2)
            for key in collect(keys(missing_successors[v]))
                if matches_template(key,typeof(node2))
                    missing_successors[v][key] -= 1
                end
            end
            # missing_successors[v][typeof(node2)] = get(missing_successors[v], typeof(node2), 0) - 1
        end
        missing_predecessors[v] = eligible_predecessors(node)
        for v2 in inneighbors(G,v)
            id2 = get_vtx_id(project_schedule, v2)
            node2 = get_node_from_id(project_schedule, id2)
            for key in collect(keys(missing_predecessors[v]))
                if matches_template(key,typeof(node2))
                    missing_predecessors[v][key] -= 1
                end
            end
            # missing_predecessors[v][typeof(node2)] = get(missing_predecessors[v], typeof(node2), 0) - 1
        end
    end
    @constraint(model, X * ones(NV) .<= n_successors);
    @constraint(model, X' * ones(NV) .<= n_predecessors);
    @show missing_predecessors
    @show missing_successors
    for v in vertices(G)
        node = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v))
        # @show v, typeof(node)
        upstream_vertices = map(e->e.dst,collect(edges(bfs_tree(G,v;dir=:in))))
        for (template, val) in missing_successors[v]
            # @show template, val
            for v2 in vertices(G)
                if v2 in upstream_vertices
                    continue
                end
                node2 = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v2))
                # @show v2, typeof(node2)
                if !matches_template(template, typeof(node2))
                    continue
                end
                # @show missing_predecessors[v]
                # @show missing_successors[v2]
                for (template2, val2) in missing_predecessors[v2]
                    # @show v2, v, val2, val, template2, template, typeof(node2)
                    if !(val > 0 && val2 > 0)
                        continue
                    end
                    if matches_template(template2,typeof(node))
                        @show v,v2,typeof(node),typeof(node2)
                        # possible to add and edge
                        # TODO build the bridge
                        new_node = align_with_predecessor(node2,node)
                        # TODO how to get dt_min? Perhaps it can be done with generate_path_spec?
                        @show dt_min = generate_path_spec(project_schedule,problem_spec,new_node).min_path_duration
                        @constraint(model, tF[v2] - (t0[v2] + dt_min) >= -Mm*(1 - X[v,v2]))
                    else
                        @constraint(model, X[v,v2] == 0)
                    end
                end
            end
        end
    end

    # assignments and associated big M constraints
    for (object_id,j) in object_id_map
        vj = get_vtx(project_schedule, object_id)
        node_j = get_node_from_id(project_schedule, object_id)
        downstream_vertices = map(e->e.dst,collect(edges(bfs_tree(G,vj;dir=:out))))
        v_collect = outneighbors(G,vj)[1]
        node_collect = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v_collect))
        for (robot_id,i) in robot_id_map
            vi = get_vtx(project_schedule, robot_id)
            node_i = get_node_from_id(project_schedule, robot_id)
            if (vi in downstream_vertices)
                @constraint(model, x[i,j] == 0) # cannot assign to a downstream robot
            else
                for v in inneighbors(G, v_collect)
                    node_go = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v))
                    if typeof(node_go) <: GO
                        start_idx = get_id(get_location_id(node_i)) # robot location
                        end_idx = get_id(get_destination_location_id(node_go)) # object location
                        dt_min = problem_spec.D[start_idx,end_idx]
                        @constraint(model, tF[v] - (t0[v] + dt_min) >= -Mm*(1 - x[i,j]))
                    end
                end
            end
        end
    end

    # "Job-shop" constraints specifying that no station may be double-booked. A station
    # can only support a single COLLECT or DEPOSIT operation at a time, meaning that all
    # the windows for these operations cannot overlap. In the constraints below, t1 and t2
    # represent the intervals for the COLLECT or DEPOSIT operations of tasks j and j2,
    # respectively. If eny of the operations for these two tasks require use of the same
    # station, we introduce a 2D binary variable y. if y = [1,0], the operation for task
    # j must occur before the operation for task j2. The opposite is true for y == [0,1].
    # We use the big M method here as well to tightly enforce the binary constraints.
    job_shop_variables = Dict{Tuple{Int,Int},JuMP.VariableRef}();
    for v in 1:nv(G)
        node = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v))
        for v2 in nv(G)
            node2 = get_node_from_id(project_schedule, get_vtx_id(project_schedule, v2))
            common_resources = intersect(resources_reserved(node),resources_reserved(node2))
            if length(common_resources) > 0
                @show common_resources
                tmax = @variable(model)
                tmin = @variable(model)
                y = @variable(model, binary=true)
                job_shop_variables[(v,v2)] = y
                @constraint(model, tmax >= t0[v])
                @constraint(model, tmax >= t0[v2])
                @constraint(model, tmin <= tF[v])
                @constraint(model, tmin <= tF[v2])

                @constraint(model, tmax - t0[v2] <= (1 - y)*Mm)
                @constraint(model, tmax - t0[v] <= y*Mm)
                @constraint(model, tmin - tF[v] >= (1 - y)*-Mm)
                @constraint(model, tmin - tF[v2] >= y*-Mm)
                @constraint(model, tmin + 1 <= tmax)
            end
        end
    end
    # cost depends only on root node(s)
    # cost_model = :MakeSpan
    cost_model = :SumOfMakeSpans
    if cost_model == :SumOfMakeSpans
        root_nodes = project_schedule.root_nodes
        @variable(model, T[1:length(root_nodes)])
        for (i,project_head) in enumerate(root_nodes)
            for v in project_head
                @show v
                @constraint(model, T[i] >= tF[v])
            end
        end
        @objective(model, Min, sum(map(v->tF[v]*get(project_schedule.weights,v,0.0), root_nodes)))
    elseif cost_model == :MakeSpan
        @variable(model, T)
        @constraint(model, T .>= tF)
        @objective(model, Min, T)
    end
    # Optimize!
    optimize!(model)
    status = termination_status(model)
    obj_val = Int(round(value(objective_function(model))))
    assignment_matrix = Int.(round.(value.(x)))

    model, status, obj_val, assignment_matrix
end
let
    M = 3
    object_ICs = Vector{OBJECT_AT}([
        OBJECT_AT(1,1),
        OBJECT_AT(2,2),
        OBJECT_AT(3,3)
        ])
    object_FCs = Vector{OBJECT_AT}([
        OBJECT_AT(1,4),
        OBJECT_AT(2,5),
        OBJECT_AT(3,6)
        ])
    robot_ICs = Dict{Int,ROBOT_AT}(
        1=>ROBOT_AT(1,7),
        2=>ROBOT_AT(2,8),
        3=>ROBOT_AT(3,9)
        )
    # Testing root nodes
    let
        project_spec = ProjectSpec(initial_conditions=object_ICs,final_conditions=object_FCs)
        add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [3], 1.0))
        @test project_spec.root_nodes == Set{Int}([1])
        add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
        @test project_spec.root_nodes == Set{Int}([2])
    end
    let
        project_spec = ProjectSpec(initial_conditions=object_ICs,final_conditions=object_FCs)
        add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [], 1.0))
        @test project_spec.root_nodes == Set{Int}([1])
        add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
        @test project_spec.root_nodes == Set{Int}([1,2])
    end
    project_spec = ProjectSpec(initial_conditions=object_ICs,final_conditions=object_FCs)
    add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [3], 1.0))
    add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
    delivery_graph = construct_delivery_graph(project_spec,M)
    problem_spec = TaskGraphProblemSpec()
end
let
    G = DiGraph(3)
    add_edge!(G,1,2)
    @test get_all_root_nodes(G) == Set([2,3])
end
# Simple Hand Crafted Problem
let
    project_spec, problem_spec, robot_ICs, optimal_assignments, env_graph = initialize_toy_problem_1()
    N = problem_spec.N
    M = problem_spec.M

    model = formulate_optimization_problem(problem_spec,Gurobi.Optimizer;OutputFlag=0);
    optimize!(model)
    @test termination_status(model) == MathOptInterface.OPTIMAL

    assignment_matrix = get_assignment_matrix(model)
    assignments = map(j->findfirst(assignment_matrix[:,j] .== 1),1:M)
    @test assignments == optimal_assignments

    project_schedule = construct_project_schedule(project_spec, problem_spec, robot_ICs, assignments);

    t0,tF,slack,local_slack = process_schedule(project_schedule)
    @test t0[get_vtx(project_schedule,RobotID(1))] == 0
    @test t0[get_vtx(project_schedule,RobotID(2))] == 0
    @test t0[get_vtx(project_schedule,RobotID(3))] == 3

    # try with perturbed start times
    t0[get_vtx(project_schedule,RobotID(2))] = 1
    t0,tF,slack,local_slack = process_schedule(project_schedule;t0=t0)
    @test t0[get_vtx(project_schedule,RobotID(1))] == 0
    @test t0[get_vtx(project_schedule,RobotID(2))] == 1
    @test t0[get_vtx(project_schedule,RobotID(3))] == 3

    @test length(get_vtx_ids(project_schedule)) == nv(get_graph(project_schedule))
    for (v,id) in enumerate(project_schedule.vtx_ids)
        @test get_vtx(project_schedule, id) == v
    end
end
# combining two project specs
let
    Random.seed!(0)
    N = 4                  # num robots
    M = 6                  # num delivery tasks
    # env_graph, vtx_grid = initialize_grid_graph_with_obstacles([10,10]);
    env_graph = initialize_grid_graph_from_vtx_grid(initialize_dense_vtx_grid(4,4))
    # N = 40                  # num robots
    # M = 60                  # num delivery tasks
    # env_graph, vtx_grid = initialize_grid_graph_with_obstacles([50,50]);
    pickup_zones = collect(1:M)
    dropoff_zones = collect(M+1:2*M)
    free_zones = collect(2*M+1:nv(env_graph))
    dist_matrix = get_dist_matrix(env_graph)

    r0 = free_zones[1:N]
    s0 = pickup_zones[1:M]
    sF = dropoff_zones[1:M]
    # r0,s0,sF = get_random_problem_instantiation(
    #     N,M,pickup_zones,dropoff_zones,free_zones)

    object_ICs = Vector{OBJECT_AT}([OBJECT_AT(o,s0[o]) for o in 1:M]) # initial_conditions
    object_FCs = Vector{OBJECT_AT}([OBJECT_AT(o,sF[o]) for o in 1:M]) # final conditions
    robot_ICs = Dict{Int,ROBOT_AT}(r => ROBOT_AT(r,r0[r]) for r in 1:N)
    # Drs, Dss = cached_pickup_and_delivery_distances(pts[r0],pts[s0],pts[sF])
    Drs, Dss = cached_pickup_and_delivery_distances(r0,s0,sF,(v1,v2)->dist_matrix[v1,v2])
    project_spec = construct_random_project_spec(M,object_ICs,object_FCs;max_parents=3,depth_bias=1.0,Δt_min=0,Δt_max=0)
    object_ICs1 = Vector{OBJECT_AT}([object_ICs[o] for o in 1:Int(M/2)])
    object_FCs1 = Vector{OBJECT_AT}([object_FCs[o] for o in 1:Int(M/2)])
    project_spec1 = construct_random_project_spec(Int(M/2),object_ICs1,object_FCs1;max_parents=3,depth_bias=0.25,Δt_min=0,Δt_max=0)
    object_FCs2 = Vector{OBJECT_AT}([object_FCs[o] for o in Int(M/2)+1:M])
    object_ICs2 = Vector{OBJECT_AT}([object_ICs[o] for o in Int(M/2)+1:M])
    project_spec2 = construct_random_project_spec(Int(M/2),object_ICs2,object_FCs2;max_parents=3,depth_bias=0.25,Δt_min=0,Δt_max=0)
    project_spec = combine_project_specs([project_spec1, project_spec2])

    delivery_graph = construct_delivery_graph(project_spec,M)

    filename = "project_spec.toml"
    open(filename, "w") do io
        TOML.print(io, TOML.parse(project_spec))
    end
    project_spec_mod = read_project_spec(filename)
    @test project_spec_mod == project_spec
end
let
    N = 4                  # num robots
    M = 6                  # num delivery tasks
    # env_graph, vtx_grid = initialize_grid_graph_with_obstacles([10,10]);
    env_graph = initialize_grid_graph_from_vtx_grid(initialize_dense_vtx_grid(4,4))
    # N = 40                  # num robots
    # M = 60                  # num delivery tasks
    # env_graph, vtx_grid = initialize_grid_graph_with_obstacles([50,50]);
    pickup_zones = collect(1:M)
    dropoff_zones = collect(M+1:2*M)
    free_zones = collect(2*M+1:nv(env_graph))
    dist_matrix = get_dist_matrix(env_graph)

    r0 = free_zones[1:N]
    s0 = pickup_zones[1:M]
    sF = dropoff_zones[1:M]
    # r0,s0,sF = get_random_problem_instantiation(
    #     N,M,pickup_zones,dropoff_zones,free_zones)

    object_ICs = Vector{OBJECT_AT}([OBJECT_AT(o,s0[o]) for o in 1:M]) # initial_conditions
    object_FCs = Vector{OBJECT_AT}([OBJECT_AT(o,sF[o]) for o in 1:M]) # final conditions
    robot_ICs = Dict{Int,ROBOT_AT}(r => ROBOT_AT(r,r0[r]) for r in 1:N)
    # Drs, Dss = cached_pickup_and_delivery_distances(pts[r0],pts[s0],pts[sF])
    Drs, Dss = cached_pickup_and_delivery_distances(r0,s0,sF,(v1,v2)->dist_matrix[v1,v2])
    project_spec = construct_random_project_spec(M,object_ICs,object_FCs;max_parents=3,depth_bias=1.0,Δt_min=0,Δt_max=0)
    object_ICs1 = Vector{OBJECT_AT}([object_ICs[o] for o in 1:Int(M/2)])
    object_FCs1 = Vector{OBJECT_AT}([object_FCs[o] for o in 1:Int(M/2)])
    project_spec1 = construct_random_project_spec(Int(M/2),object_ICs1,object_FCs1;max_parents=3,depth_bias=0.25,Δt_min=0,Δt_max=0)
    object_FCs2 = Vector{OBJECT_AT}([object_FCs[o] for o in Int(M/2)+1:M])
    object_ICs2 = Vector{OBJECT_AT}([object_ICs[o] for o in Int(M/2)+1:M])
    project_spec2 = construct_random_project_spec(Int(M/2),object_ICs2,object_FCs2;max_parents=3,depth_bias=0.25,Δt_min=0,Δt_max=0)
    project_spec = combine_project_specs([project_spec1, project_spec2])

    filename = "project_spec.toml"
    open(filename, "w") do io
        TOML.print(io, TOML.parse(project_spec))
    end
    project_spec = read_project_spec(filename)

    problem_def = SimpleProblemDef(project_spec,r0,s0,sF)
    filename = "problem_def.toml"
    open(filename, "w") do io
        TOML.print(io, TOML.parse(problem_def))
    end
    problem_def = read_problem_def(filename)

    for spec in [project_spec1, project_spec2, project_spec]
        let
            project_spec = spec
            delivery_graph = construct_delivery_graph(project_spec,M)
            project_spec, problem_spec, object_ICs, object_FCs, robot_ICs = construct_task_graphs_problem(project_spec,r0,s0,sF,dist_matrix)
            model = formulate_optimization_problem(problem_spec,Gurobi.Optimizer;OutputFlag=0);
            optimize!(model)
            @test termination_status(model) == MathOptInterface.OPTIMAL
            assignment = get_assignment_matrix(model);
            assignments = map(j->findfirst(assignment[:,j] .== 1),1:M)
            for r in N+1:N+M
                robot_ICs[r] = ROBOT_AT(r,sF[r-N])
            end
            project_schedule = construct_project_schedule(project_spec, problem_spec, object_ICs, object_FCs, robot_ICs, assignments);
            o_keys = Set(collect(keys(get_object_ICs(project_schedule))))
            input_ids = union([get_input_ids(op) for (k,op) in get_operations(project_schedule)]...)
            @test o_keys == input_ids
            rg = get_display_metagraph(project_schedule)
        end
    end
end
let
    N = 4                  # num robots
    M = 6                  # num delivery tasks
    env_graph = initialize_grid_graph_from_vtx_grid(initialize_dense_vtx_grid(4,4))
    dist_matrix = get_dist_matrix(env_graph)
    pickup_zones = collect(1:M)
    dropoff_zones = collect(M+1:2*M)
    free_zones = collect(2*M+1:nv(env_graph))

    project_spec, problem_spec, object_ICs, object_FCs, robot_ICs = construct_random_task_graphs_problem(
        N,M,pickup_zones,dropoff_zones,free_zones,dist_matrix)

    model = formulate_optimization_problem(problem_spec,Gurobi.Optimizer;OutputFlag=0);

    optimize!(model)
    @test termination_status(model) == MathOptInterface.OPTIMAL

    assignment_matrix = get_assignment_matrix(model);
    assignments = map(j->findfirst(assignment_matrix[:,j] .== 1),1:M)
    project_schedule = construct_project_schedule(project_spec, problem_spec, object_ICs, object_FCs, robot_ICs, assignments);

    o_keys = Set(collect(keys(get_object_ICs(project_schedule))))
    input_ids = union([get_input_ids(op) for (k,op) in get_operations(project_schedule)]...)
    @test o_keys == input_ids
end
