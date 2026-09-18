from robot_notes.tools import TOOL_HANDLERS, TOOL_SCHEMAS
from robot_notes import RobotNotesProvider


def test_every_schema_has_a_matching_handler_entry():
    schema_names = {schema["name"] for schema in TOOL_SCHEMAS}
    assert schema_names == set(TOOL_HANDLERS)


def test_every_handler_method_exists_on_the_provider():
    for method_name in TOOL_HANDLERS.values():
        assert hasattr(RobotNotesProvider, method_name), f"RobotNotesProvider.{method_name} is missing"


def test_every_schema_declares_a_description():
    for schema in TOOL_SCHEMAS:
        assert schema.get("description")


def test_every_parameter_declares_a_description():
    for schema in TOOL_SCHEMAS:
        for param_name, param in schema["parameters"]["properties"].items():
            assert param.get("description"), f"{schema['name']}.{param_name} has no description"


def test_required_parameters_are_declared_properties():
    for schema in TOOL_SCHEMAS:
        properties = schema["parameters"]["properties"]
        for required_name in schema["parameters"]["required"]:
            assert required_name in properties
