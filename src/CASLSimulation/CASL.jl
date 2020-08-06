# Dependencies and Imports
using JSON, DataFrames, LightGraphs, PathDistribution

# Simulation Function
function simulate(degreePlan::DegreePlan, students::Array{Student}; performance_model=PassRate, enrollment_model=Enrollment, max_credits=18, duration=8, durationLock=false, stopouts=false)

    # Create the simulation object
    simulation = Simulation(deepcopy(degreePlan))

    # Train the model
    performance_model.train(simulation.degreePlan)

    # Determine the number of students used in the simulation
    numStudents = length(students)
    simulation.numStudents = numStudents

    # Populate the enrolled students array with all students
    simulation.enrolledStudents = copy(students)

    # Reset simulation object
    simulation.graduatedStudents = Student[]
    simulation.stopoutStudents = Student[]
    simulation.gradRate = 0.0
    simulation.termGradRates = zeros(duration)
    simulation.stopoutRate = 0.0
    simulation.termStopoutRates = zeros(duration)

    numCourses = simulation.degreePlan.curriculum.num_courses

    # Assign each student a unique id
    for (i, student) in enumerate(simulation.enrolledStudents)
        student.id = i
        student.termpassed = zeros(numCourses)
    end

    # Initialize matrix to track student performance
    # Each row represents a student and each column is associated with a course.
    # A 1 signifies that the student passed the course while a 0 indicates incomplete.
    simulation.studentProgress = zeros(numStudents, numCourses)

    # Matrix to hold the number of attempts a student has made at passing a course
    attempts = ones(numStudents, numCourses)

    # Record number of simulation terms
    simulation.duration = duration

    # Initialize courses
    for course in simulation.degreePlan.curriculum.courses
        course.metadata["termenrollment"] = zeros(duration)
        course.metadata["termpassed"] = zeros(duration)
        course.metadata["students"] = Student[]
    end

    # Convenience variables
    terms = simulation.degreePlan.terms
    studentProgress = simulation.studentProgress

    # Begin simulation
    for currentTerm = 1:duration
        # Enroll students in courses
        enrollment_model.enroll!(currentTerm, simulation, max_credits)

        # Predict Performance
        for (termnum, term) in enumerate(terms)
            for course in term.courses
                for student in course.metadata["students"]
                    # Make prediction
                    predictedGrade = performance_model.predict_grade(course, student)

                    courseName = constructCourseName(course.prefix, course.num, course.name)
                    student.performance[courseName] = predictedGrade

                    # Record grade for the course
                    push!(course.metadata["grades"], predictedGrade)

                    # Check to see if the grade is passing
                    if predictedGrade > 1.67
                        # Mark that the student passed the course
                        studentProgress[student.id, course.metadata["id"]] = 1.0

                        # Log the term which the student passed the course
                        course.metadata["termpassed"][currentTerm] += 1

                        student.termpassed[course.metadata["id"]] = currentTerm
                    else
                        # Recourd the failure
                        course.metadata["failures"] += 1

                        # Increment the attempts
                        attempts[student.id, course.metadata["id"]] += 1
                    end

                    # Increment the students credit hours and points
                    student.total_credits += course.credit_hours
                    student.total_points += predictedGrade * course.credit_hours
                end
            end
        end


        # Process term performance
        for student in simulation.enrolledStudents
            # Compute the student's GPA
            student.gpa = student.total_points / student.total_credits

            # Reset the student's term credits to 0
            student.termcredits = 0
        end


        # Determine whether a student has graduated
        graduatedStudentIds = []
        for (i, student) in enumerate(simulation.enrolledStudents)
            if sum(studentProgress[student.id, :]) == numCourses
                # Add the student to the array of graduated students
                push!(simulation.graduatedStudents, student)

                # Record the semester of graduation
                student.gradsem = currentTerm

                # Record the index of the student
                push!(graduatedStudentIds, i)

                simulation.timeToDegree += currentTerm
            end
        end
        # Remove graduated students from enrolled array
        deleteat!(simulation.enrolledStudents, graduatedStudentIds)

        # Compute graduation rate as of the current term
        simulation.termGradRates[currentTerm] = length(simulation.graduatedStudents) / numStudents


        # Determine stopouts
        if stopouts
            stopoutStudentIds = []
            for (i, student) in enumerate(simulation.enrolledStudents)
                # Predict stopout
                student.stopout = performance_model.predict_stopout(student, currentTerm, simulation.degreePlan["stopoutModel"])

                if student.stopout
                    # Add to array of stopouts
                    push!(simulation.stopoutStudents, student)

                    # Record index of the student
                    push!(stopoutStudentIds, i)
                end
            end

            # Remove graduated students from the array of enrolled students
            deleteat!(simulation.enrolledStudents, stopoutStudentIds)

            # Compute stopout rate as of the current term
            simulation.termStopoutRates[currentTerm] = length(simulation.stopoutStudents) / numStudents
        end

        # Check to see if all students have graduated
        if length(simulation.enrolledStudents) == 0 && !durationLock
            simulation.duration = currentTerm
            simulation.timeToDegree /= numStudents
            break
        end
    end

    # Compute graduation rate
    simulation.gradRate = length(simulation.graduatedStudents) / numStudents

    # Compute stopout rate
    simulation.stopoutRate = length(simulation.stopoutStudents) / numStudents

    return simulation
end


####################################################################
# Helper funcions
function constructCourseName(prefix, num, name)
    return prefix * " " * string(num) * " " * name
end



# Function that determines wheter a student can enroll in a course
function canEnroll(student, course, studentProgress, max_credits, term)
        # Find the prereq ids of the current course
    prereqIds = map(x -> x.id, course.prereqs)

    !in(student, course.students) &&
        (length(course.prereqs) == 0 || sum(studentProgress[student.id, prereqIds]) == length(course.prereqs)) &&       # No Prereqs or the student has completed them
        studentProgress[student.id, course.id] == 0.0 &&                                                                # The student has not already completed the course
        student.termcredits + course.credits <= max_credits &&                                                          # The student will not exceed the maximum number of credit hours
        course.termReq <= term &&                                                                                       # The student must wait until the term req has been met
        enrolledInCoreqs(student, course, studentProgress)                                                              # The student is enrolled in or has completed coreqs
end

# Determines whether a student is enrolled in or has completed coreqs for a given course
function enrolledInCoreqs(student, course, studentProgress)
    enrolled = true

    for coreq in course.coreqs
        enrolled =  enrolled && (in(student, coreq.students) || studentProgress[student.id, coreq.id] == 1.0)
    end

    return enrolled
end
